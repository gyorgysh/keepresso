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
