import Testing
@testable import KeepressoCore

private final class FanSMC: SMCFanAccess {
    var values: [String: Double]
    var writes: [(key: String, value: Double)] = []

    init(modeKeys: [String]) {
        values = ["FNum": Double(modeKeys.count)]
        for (fan, key) in modeKeys.enumerated() {
            values[key] = 0
            values["F\(fan)Mn"] = 1350
            values["F\(fan)Mx"] = 5350
            values["F\(fan)Ac"] = 4000
            values["F\(fan)Tg"] = 4000
        }
    }

    func keyInfo(_ name: String) -> (size: Int, type: String)? {
        guard values[name] != nil else { return nil }
        return name.hasSuffix("Md") || name.hasSuffix("md") || name == "FNum"
            ? (1, "ui8 ") : (4, "flt ")
    }

    func read(_ name: String) -> Double? { values[name] }

    func write(_ name: String, value: Double) -> UInt8? {
        writes.append((name, value))
        guard values[name] != nil else { return SMCConnection.ResultCode.keyNotFound }
        values[name] = value
        return SMCConnection.ResultCode.success
    }
}

@Test func m5LowercaseModesBoostBothFansAndRestoreAutomaticControl() {
    let smc = FanSMC(modeKeys: ["F0md", "F1md"])
    let controller = SMCFanController(access: smc)

    #expect(controller.setForced(percent: 90) == .ok)
    #expect(smc.values["F0md"] == 1)
    #expect(smc.values["F1md"] == 1)
    #expect(smc.values["F0Tg"] == 4950)
    #expect(smc.values["F1Tg"] == 4950)
    #expect(controller.restoreAuto())
    #expect(smc.values["F0md"] == 0)
    #expect(smc.values["F1md"] == 0)
    #expect(!smc.writes.contains { $0.key == "F0Md" || $0.key == "F1Md" })
}

@Test func fanModeCasingIsDiscoveredPerFanAndBoostPreservesExistingCooling() {
    let smc = FanSMC(modeKeys: ["F0Md", "F1md"])
    let controller = SMCFanController(access: smc)

    #expect(controller.setForced(percent: 10) == .ok)
    #expect(smc.values["F0Tg"] == 4000)
    #expect(smc.values["F1Tg"] == 4000)
    #expect(controller.restoreAuto())
    #expect(smc.values["F0Md"] == 0)
    #expect(smc.values["F1md"] == 0)
}

@Test func legacyUppercaseModesStillBoostAndRestore() {
    let smc = FanSMC(modeKeys: ["F0Md"])
    let controller = SMCFanController(access: smc)

    #expect(controller.setForced(percent: 90) == .ok)
    #expect(smc.values["F0Md"] == 1)
    #expect(controller.restoreAuto())
    #expect(smc.values["F0Md"] == 0)
}

@Test func missingModeKeyRefusesBoostWithoutWritingTarget() {
    let smc = FanSMC(modeKeys: ["F0md"])
    smc.values.removeValue(forKey: "F0md")
    let controller = SMCFanController(access: smc)

    #expect(controller.setForced(percent: 90) == .failed)
    #expect(smc.values["F0Tg"] == 4000)
    #expect(!controller.restoreAuto())
}
