import Testing
@testable import KeepressoCore

@Test func fourCCRoundTripsKeyNames() {
    for name in ["FNum", "F0Ac", "F0Tg", "Ftst", "TC0P", "#KEY"] {
        #expect(SMCCodec.name(SMCCodec.fourCC(name)) == name)
    }
    // The known value everyone's SMC code agrees on.
    #expect(SMCCodec.fourCC("#KEY") == 0x234B4559)
}

@Test func fltIsLittleEndianIEEE754() {
    // 2000.0 as float = 0x44FA0000, little-endian on the wire.
    let bytes = SMCCodec.encode(type: "flt ", value: 2000)
    #expect(bytes == [0x00, 0x00, 0xFA, 0x44])
    #expect(SMCCodec.decode(type: "flt ", bytes: [0x00, 0x00, 0xFA, 0x44]) == 2000)
}

@Test func fpe2IsBigEndianFourthsOfRPM() {
    // 2000 RPM in 14.2 fixed point = 8000 = 0x1F40, big-endian.
    let bytes = SMCCodec.encode(type: "fpe2", value: 2000)
    #expect(bytes == [0x1F, 0x40])
    #expect(SMCCodec.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000)
    // Quarter-RPM resolution survives.
    #expect(SMCCodec.decode(type: "fpe2", bytes: [0x00, 0x01]) == 0.25)
}

@Test func sp78DecodesSignedTemperatures() {
    // 45.5 °C = 0x2D80; -1 °C = 0xFF00.
    #expect(SMCCodec.decode(type: "sp78", bytes: [0x2D, 0x80]) == 45.5)
    #expect(SMCCodec.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
}

@Test func unsignedIntegersDecodeBigEndian() {
    #expect(SMCCodec.decode(type: "ui8 ", bytes: [2]) == 2) // FNum on a two-fan Mac
    #expect(SMCCodec.decode(type: "ui16", bytes: [0x01, 0x00]) == 256)
    #expect(SMCCodec.decode(type: "ui32", bytes: [0x00, 0x00, 0x01, 0x00]) == 256)
}

@Test func unknownTypesRefuseToCodec() {
    #expect(SMCCodec.decode(type: "ch8*", bytes: [65, 66]) == nil)
    #expect(SMCCodec.encode(type: "sp78", value: 50) == nil) // temps are never written
}

@Test func realSMCReadPathsNeverCrash() {
    // Hardware smoke test: values vary per machine and may be absent entirely
    // (a VM, a CI runner), so this asserts nothing about them; it proves the
    // real read paths return instead of crashing, on whatever runs the suite.
    let info = SMCFanInfo()
    print("SMC smoke: fanCount =", info.fanCount().map(String.init) ?? "nil",
          "F0Ac =", info.currentRPM().map { String(format: "%.0f", $0) } ?? "nil")
    for fan in 0..<(info.fanCount() ?? 0) {
        print("SMC smoke: fan", fan,
              "rpm =", info.rpm(ofFan: fan).map { String(format: "%.0f", $0) } ?? "nil",
              "range =", info.rpmRange(ofFan: fan).map { "\($0.min)...\($0.max)" } ?? "nil")
    }
    let sensors = SMCThermalSensors()
    let found = sensors.discoverSensors()
    print("SMC smoke: discovered", found.count, "T-sensors",
          found.prefix(5).map(\.id))
    if let first = found.first {
        _ = sensors.readCelsius(ids: [first.id])
    }
}

@Test func plausibilityBandRejectsNonThermometers() {
    #expect(SMCThermalSensors.isPlausibleCelsius(45))
    #expect(SMCThermalSensors.isPlausibleCelsius(105))
    #expect(!SMCThermalSensors.isPlausibleCelsius(0))    // unpopulated sensor
    #expect(!SMCThermalSensors.isPlausibleCelsius(-127)) // disconnected probe
    #expect(!SMCThermalSensors.isPlausibleCelsius(400))  // a counter, not a temp
}
