import Testing
@testable import KeepressoCore

private enum PumpValue: Equatable, Sendable {
    case activeA
    case activeB
    case activeC
    case clear
}

@Test func serializedPumpRunsOnlyCurrentThenNewestPendingValue() {
    var pump = SerializedLatestRequestPump<PumpValue>()
    let first = pump.submit(.activeA)
    #expect(first?.value == .activeA)
    #expect(pump.current == first)

    let queuedB = pump.submit(.activeB)
    #expect(queuedB == nil)
    #expect(pump.pending?.value == .activeB)
    let queuedC = pump.submit(.activeC)
    #expect(queuedC == nil)
    #expect(pump.pending?.value == .activeC)

    let firstCompletion = pump.complete(first!)
    #expect(firstCompletion?.wasLatest == false)
    #expect(firstCompletion?.next?.value == .activeC)
    #expect(pump.current?.value == .activeC)
    #expect(pump.pending == nil)

    // Duplicate or delayed callbacks cannot release the new current slot.
    let duplicate = pump.complete(first!)
    #expect(duplicate == nil)
    let final = pump.current!
    let finalCompletion = pump.complete(final)
    #expect(finalCompletion?.wasLatest == true)
    #expect(finalCompletion?.next == nil)
    #expect(pump.isIdle)
}

@Test func serializedPumpOrdersDisableClearAfterActiveInstall() {
    var pump = SerializedLatestRequestPump<PumpValue>()
    let active = pump.submit(.activeA)!
    let queuedClear = pump.submit(.clear)
    #expect(queuedClear == nil)

    let completion = pump.complete(active)
    #expect(completion?.next?.value == .clear)
    #expect(pump.current?.value == .clear)
    #expect(!pump.isIdle)

    let clear = pump.current!
    let clearCompletion = pump.complete(clear)
    #expect(clearCompletion?.wasLatest == true)
    #expect(pump.isIdle)
}

@Test func serializedPumpCoalescesIdenticalWorkAndAllowsBoundedRetry() {
    var pump = SerializedLatestRequestPump<PumpValue>()
    let first = pump.submit(.activeA)!
    let firstRevision = pump.latestRevision
    let duplicate = pump.submit(.activeA)
    #expect(duplicate == nil)
    #expect(pump.latestRevision == firstRevision)

    let completion = pump.complete(first)
    #expect(completion?.wasLatest == true)
    let retry = pump.submit(.activeA, retryAttempt: 1)
    #expect(retry?.retryAttempt == 1)
    #expect(retry?.revision == firstRevision + 1)
}

@Test func onlyLatestCompletionMayCommitDesiredBookkeepingOrScheduleRetry() {
    var pump = SerializedLatestRequestPump<PumpValue>()
    let activeA = pump.submit(.activeA)!
    let queuedB = pump.submit(.activeB)
    #expect(queuedB == nil)

    var committed: PumpValue?
    var retryRevision: UInt64?
    let stale = pump.complete(activeA)!
    if stale.wasLatest { committed = activeA.value }
    if stale.wasLatest { retryRevision = activeA.revision }
    #expect(committed == nil)
    #expect(retryRevision == nil)

    let activeB = stale.next!
    let latest = pump.complete(activeB)!
    if latest.wasLatest { committed = activeB.value }
    #expect(committed == .activeB)

    // A rejected latest request may be retried after its current slot closes.
    if latest.wasLatest { retryRevision = activeB.revision }
    #expect(retryRevision == activeB.revision)
    let retry = pump.submit(activeB.value, retryAttempt: 1)
    #expect(retry?.value == .activeB)
    #expect(retry?.retryAttempt == 1)
}

@Test func forcedRunGateNeverLosesForceDuringDiscovery() {
    var gate = CoalescedForceRunGate()
    let began = gate.begin(force: false)
    #expect(began)
    let skippedRegular = gate.begin(force: false)
    #expect(!skippedRegular)
    let queuedForce = gate.begin(force: true)
    #expect(!queuedForce)
    let stillSkipped = gate.begin(force: false)
    #expect(!stillSkipped)
    let rerun = gate.finish()
    #expect(rerun)

    let beganForced = gate.begin(force: true)
    #expect(beganForced)
    let noFurtherRerun = gate.finish()
    #expect(!noFurtherRerun)
    #expect(!gate.isRunning)
}
