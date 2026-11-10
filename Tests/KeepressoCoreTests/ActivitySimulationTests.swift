import Testing
import Foundation
@testable import KeepressoCore

@Test func activityPokeKindMatchesTheMethod() {
    var options = SleepPreventionOptions(simulateUserActivity: true)
    #expect(options.activityPokeKind == .powerWarp)
    #expect(options.activitySimulationMethod.pokeInterval == 30)
    #expect(!options.activitySimulationMethod.needsAccessibility)

    options.activitySimulationMethod = .f15
    #expect(options.activityPokeKind == .key(ActivitySimulationMethod.f15KeyCode))
    #expect(options.activitySimulationMethod.pokeInterval == 60)
    #expect(options.activitySimulationMethod.needsAccessibility)

    options.activitySimulationMethod = .shift
    #expect(options.activityPokeKind == .key(ActivitySimulationMethod.shiftKeyCode))

    options.activitySimulationMethod = .mouseMove
    #expect(options.activityPokeKind == .mouseMove)

    options.activitySimulationMethod = .specifiedKey
    #expect(options.activityPokeKind == .powerWarp)
    options.activitySimulationKeyCode = 0x71
    #expect(options.activityPokeKind == .key(0x71))
    options.activitySimulationKeyCode = -1
    #expect(options.activityPokeKind == .powerWarp)
}

@Test func activitySimulationMethodCasesStayStable() {
    #expect(ActivitySimulationMethod.powerWarp.rawValue == "powerWarp")
    #expect(ActivitySimulationMethod.f15.rawValue == "f15")
    #expect(ActivitySimulationMethod.shift.rawValue == "shift")
    #expect(ActivitySimulationMethod.specifiedKey.rawValue == "specifiedKey")
    #expect(ActivitySimulationMethod.mouseMove.rawValue == "mouseMove")
    #expect(ActivitySimulationMethod.f15KeyCode == 0x71)
    #expect(ActivitySimulationMethod.shiftKeyCode == 0x38)
}

@Test func specifiedKeyCarriesItsRecordedModifiers() {
    var options = SleepPreventionOptions(
        simulateUserActivity: true,
        activitySimulationMethod: .specifiedKey,
        activitySimulationKeyCode: 0x4F, // F18
        activitySimulationKeyModifiers: [.control]
    )
    #expect(options.activityPokeKind == .key(0x4F, modifiers: [.control]))

    // A modifier key carries its own flag: extra modifiers are dropped.
    options.activitySimulationKeyCode = 0x3B // Control
    #expect(options.activityPokeKind == .key(0x3B))

    // The fixed methods never pick up the specified key's modifiers.
    options.activitySimulationMethod = .f15
    #expect(options.activityPokeKind == .key(ActivitySimulationMethod.f15KeyCode))
}

@Test func specifiedKeyModifiersRoundTripAndDecodeForgivingly() throws {
    let options = SleepPreventionOptions(
        activitySimulationMethod: .specifiedKey,
        activitySimulationKeyCode: 0x4F,
        activitySimulationKeyModifiers: [.control, .option]
    )
    let data = try JSONEncoder().encode(options)
    #expect(try JSONDecoder().decode(SleepPreventionOptions.self, from: data) == options)

    // An older blob has no modifiers field: none.
    let old = Data(#"{"activitySimulationMethod":"specifiedKey","activitySimulationKeyCode":79}"#.utf8)
    #expect(try JSONDecoder().decode(SleepPreventionOptions.self, from: old).activitySimulationKeyModifiers == [])

    // Bits a newer build might add are masked off, a wrong type falls back.
    let future = Data(#"{"activitySimulationKeyModifiers":255}"#.utf8)
    #expect(try JSONDecoder().decode(SleepPreventionOptions.self, from: future).activitySimulationKeyModifiers == .all)
    let wrong = Data(#"{"activitySimulationKeyModifiers":"control"}"#.utf8)
    #expect(try JSONDecoder().decode(SleepPreventionOptions.self, from: wrong).activitySimulationKeyModifiers == [])
}
