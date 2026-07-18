import Testing
@testable import KeepressoCore

private final class CountingEvaluator: TriggerEvaluating {
    var satisfied: Bool
    private(set) var ticks = 0

    init(_ satisfied: Bool) {
        self.satisfied = satisfied
    }

    func tick() { ticks += 1 }
    func isSatisfied() -> Bool { satisfied }
}

@Test func anyTriggerEvaluatorTicksEveryChildWithoutShortCircuiting() {
    let first = CountingEvaluator(true)
    let second = CountingEvaluator(false)
    let combined = AnyTriggerEvaluator([first, second])

    combined.tick()
    #expect(first.ticks == 1)
    #expect(second.ticks == 1)
    #expect(combined.isSatisfied())

    first.satisfied = false
    #expect(!combined.isSatisfied())
}

@Test func mutableTriggerEvaluatorTracksExternalUnionState() {
    let external = MutableTriggerEvaluator()
    #expect(!external.isSatisfied())
    external.isOn = true
    #expect(external.isSatisfied())
}
