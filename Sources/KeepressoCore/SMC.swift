import Foundation
import IOKit

/// Pure encoders/decoders for SMC key names and data types. The System
/// Management Controller speaks four-character keys and a small set of wire
/// encodings; nothing here touches hardware, so it's all directly unit-tested.
///
/// Encodings seen in the wild:
/// - `flt `: 4-byte IEEE-754 float, little-endian (Apple Silicon RPM, temps)
/// - `fpe2`: unsigned 14.2 fixed point, big-endian (Intel fan RPM)
/// - `sp78`: signed 7.8 fixed point, big-endian (Intel temperatures)
/// - `ui8 `/`ui16`/`ui32`: unsigned integers, big-endian (counts, modes)
/// The decoder trusts the data type the SMC reports per key, never the CPU
/// architecture: keys are the authority on their own encoding.
public enum SMCCodec {
    /// "F0Ac" → the UInt32 the SMC protocol carries key names in.
    public static func fourCC(_ name: String) -> UInt32 {
        precondition(name.utf8.count == 4, "SMC keys are exactly four characters")
        return name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// The inverse of ``fourCC(_:)``, for describing discovered keys.
    public static func name(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Decode a value by its SMC-reported type name. Returns `nil` for types
    /// this codec doesn't speak (callers skip such keys).
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = bytes[0...3].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256
        case "ui8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes[0...3].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            return nil
        }
    }

    /// Encode a value for writing, by the key's reported type. `nil` when the
    /// type isn't writable by this codec.
    public static func encode(type: String, value: Double) -> [UInt8]? {
        switch type {
        case "flt ":
            let raw = Float(value).bitPattern
            return [0, 8, 16, 24].map { UInt8((raw >> $0) & 0xff) }
        case "fpe2":
            let raw = UInt16((value * 4).rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ":
            return [UInt8(min(max(value, 0), 255))]
        default:
            return nil
        }
    }
}

/// A connection to the `AppleSMC` IOKit user client. Reads (temperatures, fan
/// speeds, key discovery) work unprivileged; writes are enforced root by the
/// SMC itself, so only the privileged helper ever calls ``write(key:value:)``.
///
/// The struct layout and selector below are private knowledge (the same 80-byte
/// `SMCParamStruct` every monitoring tool ships), expressed in plain Swift so
/// this file builds anywhere Core does; a machine or OS where the service or
/// layout stops cooperating degrades to `nil` reads, never a crash.
public final class SMCConnection {
    // Command bytes for `data8` and the user-client method selector.
    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyFromIndex = 8
        case keyInfo = 9
    }
    private static let handleYPCEvent: UInt32 = 2

    /// SMC-level result codes worth naming. `notWritable` (0x82) is what M3+
    /// firmware answers manual fan-mode writes with until `Ftst` is set.
    public enum ResultCode {
        public static let success: UInt8 = 0
        public static let notWritable: UInt8 = 0x82
        public static let keyNotFound: UInt8 = 0x84
    }

    /// The 80-byte parameter block AppleSMC's YPC handler expects. Field
    /// offsets must match the C `SMCParamStruct` exactly, including the
    /// compiler padding the nested C structs imply: `pLimitData` starts at 12
    /// (vers is 6 bytes padded to 4-byte alignment), `keyInfo` is 9 bytes
    /// padded to 12, so `result` sits at 40 and the command byte `data8` at
    /// 42. The explicit pad fields below reproduce that; the initializer
    /// asserts the total stride.
    private struct ParamStruct {
        var key: UInt32 = 0
        var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0
        var versReserved: UInt8 = 0
        var versRelease: UInt16 = 0
        var versPad: UInt16 = 0
        var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
        var pLimitCPU: UInt32 = 0, pLimitGPU: UInt32 = 0, pLimitMem: UInt32 = 0
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var keyInfoPad1: UInt8 = 0, keyInfoPad2: UInt8 = 0, keyInfoPad3: UInt8 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data8Pad: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = IO_OBJECT_NULL
    /// Key info (size + type) cached per key: it never changes while booted,
    /// and every read/write needs it first.
    private var keyInfoCache: [UInt32: (size: Int, type: String)] = [:]
    private let lock = NSLock()

    public init?() {
        assert(MemoryLayout<ParamStruct>.stride == 80, "SMCParamStruct layout drifted")
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS,
              connection != IO_OBJECT_NULL else { return nil }
    }

    deinit {
        if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
    }

    /// One YPC round-trip. Returns nil when the kernel call itself failed;
    /// SMC-level failures come back in `result`.
    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        var output = ParamStruct()
        var outputSize = MemoryLayout<ParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, Self.handleYPCEvent,
            &input, MemoryLayout<ParamStruct>.stride,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    /// The key's wire size and type name, cached.
    public func keyInfo(_ name: String) -> (size: Int, type: String)? {
        let key = SMCCodec.fourCC(name)
        lock.lock(); defer { lock.unlock() }
        if let cached = keyInfoCache[key] { return cached }
        var input = ParamStruct()
        input.key = key
        input.data8 = Command.keyInfo.rawValue
        guard let output = call(input), output.result == ResultCode.success else { return nil }
        let info = (size: Int(output.keyInfoDataSize), type: SMCCodec.name(output.keyInfoDataType))
        keyInfoCache[key] = info
        return info
    }

    /// Read and decode one key, or nil (missing key, undecodable type, or a
    /// failed call).
    public func read(_ name: String) -> Double? {
        guard let info = keyInfo(name) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var input = ParamStruct()
        input.key = SMCCodec.fourCC(name)
        input.keyInfoDataSize = UInt32(info.size)
        input.data8 = Command.readKey.rawValue
        guard let output = call(input), output.result == ResultCode.success else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return SMCCodec.decode(type: info.type, bytes: bytes)
    }

    /// Write one key, encoding by its reported type. Returns the SMC result
    /// code (0 = success, ``ResultCode/notWritable`` = firmware refused), or
    /// nil when the call never reached the SMC. Root-only by SMC enforcement.
    public func write(_ name: String, value: Double) -> UInt8? {
        guard let info = keyInfo(name),
              let bytes = SMCCodec.encode(type: info.type, value: value),
              bytes.count == info.size
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        var input = ParamStruct()
        input.key = SMCCodec.fourCC(name)
        input.keyInfoDataSize = UInt32(info.size)
        input.data8 = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
        }
        guard let output = call(input) else { return nil }
        return output.result
    }

    /// Every key the SMC exposes, via the `#KEY` count + by-index lookups.
    /// A few thousand entries; callers filter and cache.
    public func allKeyNames() -> [String] {
        guard let count = read("#KEY").map(Int.init), count > 0, count < 16384 else { return [] }
        var names: [String] = []
        names.reserveCapacity(count)
        lock.lock(); defer { lock.unlock() }
        for index in 0..<count {
            var input = ParamStruct()
            input.data8 = Command.keyFromIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = call(input), output.result == ResultCode.success else { continue }
            names.append(SMCCodec.name(output.key))
        }
        return names
    }
}

/// Fan presence and speed over the SMC, unprivileged. `FNum` is the fan count
/// (0 on fanless machines), `F0Ac` the first fan's actual RPM.
public final class SMCFanInfo: FanInfoReading {
    private let smc: SMCConnection?

    public init(smc: SMCConnection? = SMCConnection()) {
        self.smc = smc
    }

    public func fanCount() -> Int? {
        smc?.read("FNum").map(Int.init)
    }

    public func currentRPM() -> Double? {
        smc?.read("F0Ac")
    }

    public func rpm(ofFan index: Int) -> Double? {
        smc?.read("F\(index)Ac")
    }

    public func rpmRange(ofFan index: Int) -> (min: Double, max: Double)? {
        guard let min = smc?.read("F\(index)Mn"),
              let max = smc?.read("F\(index)Mx"),
              max > min
        else { return nil }
        return (min, max)
    }
}

/// The real forced-fan backend over SMC writes, used only inside the helper
/// daemon: fan-key writes are root-only, enforced by the SMC itself.
///
/// Boost only, by construction: each fan's target is clamped to at least the
/// RPM it was already spinning at when the boost first engaged (and never
/// below its reported minimum), so a "boost to 50%" during an emergency can
/// only add cooling, never remove what the system's own control had chosen.
public final class SMCFanController: FanControlling, @unchecked Sendable {
    private let smc: SMCConnection?
    private let lock = NSLock()
    /// Per-fan RPM at the moment the current boost engaged (the clamp floor);
    /// cleared when auto control is restored.
    private var engageFloor: [Int: Double] = [:]

    public init(smc: SMCConnection? = SMCConnection()) {
        self.smc = smc
    }

    public func fanCount() -> Int? {
        smc?.read("FNum").map(Int.init)
    }

    public func setForced(percent: Int) -> FanWriteResult {
        guard let smc, let count = fanCount(), count > 0 else { return .failed }
        lock.lock()
        defer { lock.unlock() }
        var needsUnlock = false
        var allOK = true
        for fan in 0..<count {
            let minRPM = smc.read("F\(fan)Mn") ?? 0
            let maxRPM = smc.read("F\(fan)Mx") ?? 0
            guard maxRPM > minRPM else {
                allOK = false
                continue
            }
            if engageFloor[fan] == nil {
                engageFloor[fan] = smc.read("F\(fan)Ac") ?? 0
            }
            let requested = minRPM + Double(percent) / 100 * (maxRPM - minRPM)
            let target = min(max(requested, engageFloor[fan] ?? 0, minRPM), maxRPM)

            switch smc.write("F\(fan)Md", value: 1) {
            case SMCConnection.ResultCode.success:
                break
            case SMCConnection.ResultCode.notWritable:
                needsUnlock = true
                allOK = false
                continue
            default:
                allOK = false
                continue
            }
            switch smc.write("F\(fan)Tg", value: target) {
            case SMCConnection.ResultCode.success:
                break
            case SMCConnection.ResultCode.notWritable:
                needsUnlock = true
                allOK = false
            default:
                allOK = false
            }
        }
        if needsUnlock { return .needsUnlock }
        return allOK ? .ok : .failed
    }

    public func unlock() -> Bool {
        smc?.write("Ftst", value: 1) == SMCConnection.ResultCode.success
    }

    public func restoreAuto() -> Bool {
        guard let smc, let count = fanCount(), count > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        var ok = true
        for fan in 0..<count where smc.write("F\(fan)Md", value: 0) != SMCConnection.ResultCode.success {
            ok = false
        }
        // Clear the test-mode unlock if it was ever set; harmless when not.
        _ = smc.write("Ftst", value: 0)
        engageFloor.removeAll()
        return ok
    }
}

/// Temperature sensors over SMC keys, the Intel read path (Apple Silicon uses
/// the app-side HID backend, which has real sensor names). Discovers `T…` keys
/// that decode to a plausible temperature; the key itself is both id and name.
public final class SMCThermalSensors: ThermalSensorReading {
    private let smc: SMCConnection?
    private var discovered: [ThermalSensor]?

    public init(smc: SMCConnection? = SMCConnection()) {
        self.smc = smc
    }

    public func discoverSensors() -> [ThermalSensor] {
        if let discovered { return discovered }
        guard let smc else { return [] }
        let sensors = smc.allKeyNames()
            .filter { $0.hasPrefix("T") }
            .compactMap { name -> ThermalSensor? in
                guard let value = smc.read(name), Self.isPlausibleCelsius(value) else { return nil }
                return ThermalSensor(id: name, name: name)
            }
            .sorted { $0.id < $1.id }
        discovered = sensors
        return sensors
    }

    public func readCelsius(ids: [String]) -> [String: Double]? {
        guard let smc, !ids.isEmpty else { return nil }
        var result: [String: Double] = [:]
        for id in ids where id.utf8.count == 4 {
            if let value = smc.read(id), Self.isPlausibleCelsius(value) {
                result[id] = value
            }
        }
        return result
    }

    /// Filters out the non-thermometers hiding under `T…` (timers, flags):
    /// a die or proximity sensor on a running Mac reads well inside this band.
    /// Public because the app's HID sensor path applies the same filter.
    public static func isPlausibleCelsius(_ value: Double) -> Bool {
        value > 1 && value < 130
    }
}
