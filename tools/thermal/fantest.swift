// Hardware validation driver for the SMC fan path (see the thermal milestone's
// validation matrix). Reads always work; the forced-write test needs root,
// since the SMC enforces that per key.
//
// Build and run from the repo root:
//
//   swiftc -parse-as-library -o /tmp/fantest \
//     Sources/KeepressoCore/SMC.swift Sources/KeepressoCore/Thermal.swift \
//     Sources/KeepressoCore/HelperEngine.swift Sources/KeepressoCore/Localization.swift \
//     tools/thermal/fantest.swift
//   /tmp/fantest              # read-only: fans, sensors
//   sudo /tmp/fantest boost   # forced-fan test: boost to 70% for 15 s, restore
//
// The boost test reports exactly what the firmware answered (including the
// M3+ 0x82 rejection and whether the Ftst unlock cleared it), re-asserts once
// a second the way the helper daemon does, and always restores auto control,
// also on Ctrl-C.

import Foundation

@main
struct FanTest {
    static func main() {
        let info = SMCFanInfo()
        print("fanCount:", info.fanCount().map(String.init) ?? "nil (SMC unreachable)")
        print("F0Ac RPM:", info.currentRPM().map { String(format: "%.0f", $0) } ?? "nil")
        if let smc = SMCConnection() {
            for fan in 0..<(info.fanCount() ?? 0) {
                let mn = smc.read("F\(fan)Mn").map { String(format: "%.0f", $0) } ?? "?"
                let mx = smc.read("F\(fan)Mx").map { String(format: "%.0f", $0) } ?? "?"
                let ac = smc.read("F\(fan)Ac").map { String(format: "%.0f", $0) } ?? "?"
                print("fan \(fan): min \(mn), max \(mx), actual \(ac)")
            }
        }
        let sensors = SMCThermalSensors()
        let found = sensors.discoverSensors()
        print("SMC T-sensors:", found.count)

        guard CommandLine.arguments.contains("boost") else {
            print("(pass 'boost' with sudo to run the forced-fan test)")
            return
        }
        guard getuid() == 0 else {
            print("boost needs root: sudo /tmp/fantest boost")
            exit(1)
        }

        let fans = SMCFanController()
        // Restore on Ctrl-C too; never leave fans pinned.
        signal(SIGINT) { _ in
            _ = SMCFanController().restoreAuto()
            print("\nrestored auto on interrupt")
            exit(0)
        }

        print("forcing fans to 70% for 15 s…")
        var result = fans.setForced(percent: 70)
        print("setForced:", result)
        if result == .needsUnlock {
            print("firmware wants the Ftst unlock (expected on M3 and newer); unlocking…")
            let unlocked = fans.unlock()
            print("Ftst write:", unlocked ? "ok" : "FAILED")
            result = fans.setForced(percent: 70)
            print("setForced after unlock:", result)
        }
        for second in 1...15 {
            Thread.sleep(forTimeInterval: 1)
            _ = fans.setForced(percent: 70) // the daemon's re-assert tick
            if second % 5 == 0 {
                let rpm = info.currentRPM().map { String(format: "%.0f", $0) } ?? "?"
                print("t+\(second)s F0Ac: \(rpm) RPM")
            }
        }
        print("restoring auto:", fans.restoreAuto() ? "ok" : "FAILED")
        Thread.sleep(forTimeInterval: 3)
        print("F0Ac after restore:", info.currentRPM().map { String(format: "%.0f", $0) } ?? "?")
    }
}
