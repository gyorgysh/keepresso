import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Codec

@Test func decisionLogCodecRoundTripsALine() throws {
    let event = PersistedSessionEvent(
        date: Date(timeIntervalSince1970: 1_700_000_000),
        began: true,
        reason: "Started manually",
        kind: .sessionStarted,
        batteryPercent: 80
    )
    let line = try #require(DecisionLogCodec.encodeLine(event))
    let decoded = DecisionLogCodec.decode(line)
    #expect(decoded.count == 1)
    #expect(decoded[0].began == true)
    #expect(decoded[0].reason == "Started manually")
    #expect(decoded[0].kind == .sessionStarted)
    #expect(decoded[0].batteryPercent == 80)
}

@Test func decisionLogCodecSkipsCorruptLines() {
    var data = Data("this is not json\n".utf8)
    if let good = DecisionLogCodec.encodeLine(PersistedSessionEvent(
        date: Date(timeIntervalSince1970: 1), began: false, reason: "ok"
    )) {
        data.append(good)
    }
    let decoded = DecisionLogCodec.decode(data)
    #expect(decoded.count == 1)
    #expect(decoded.first?.reason == "ok")
}

@Test func decisionLogCodecRotationKeepsASuffixUnderTheCap() {
    var events: [PersistedSessionEvent] = []
    for i in 0 ..< 200 {
        events.append(PersistedSessionEvent(
            date: Date(timeIntervalSince1970: TimeInterval(i)),
            began: i % 2 == 0,
            reason: String(repeating: "x", count: 80) + " \(i)"
        ))
    }
    var raw = Data()
    for event in events {
        if let line = DecisionLogCodec.encodeLine(event) { raw.append(line) }
    }
    let rotated = DecisionLogCodec.rotate(raw, maxBytes: 4_000)
    #expect(rotated.count <= 4_000)
    let decoded = DecisionLogCodec.decode(rotated)
    #expect(!decoded.isEmpty)
    // Newest event survives.
    #expect(decoded.last?.reason.hasSuffix(" 199") == true)
}

// MARK: - File store + persister

@Test func fileLogStoreAppendAndLoad() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-log-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = FileLogStore(fileURL: url)
    let event = PersistedSessionEvent(
        date: Date(timeIntervalSince1970: 42), began: true, reason: "hi")
    let line = try #require(DecisionLogCodec.encodeLine(event))
    store.append(line)
    store.append(line)
    #expect(DecisionLogCodec.decode(store.load()).count == 2)
}

@MainActor
@Test func persisterLoadsASuffixIntoMemoryShape() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepresso-log-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = FileLogStore(fileURL: url)
    let persister = DecisionLogPersister(store: store)
    for i in 0 ..< 5 {
        persister.append(PersistedSessionEvent(
            date: Date(timeIntervalSince1970: TimeInterval(i)),
            began: true, reason: "e\(i)"
        ))
    }
    let recent = persister.loadRecent()
    #expect(recent.map(\.reason) == ["e0", "e1", "e2", "e3", "e4"])
}

// MARK: - Stats

@Test func awakeStatsPairsSessionsAndSplitsMidnight() {
    let cal = Calendar(identifier: .gregorian)
    var components = DateComponents(year: 2026, month: 7, day: 17, hour: 23, minute: 0)
    let start = cal.date(from: components)!
    components.day = 18
    components.hour = 1
    let end = cal.date(from: components)!
    let events = [
        PersistedSessionEvent(date: start, began: true, reason: "Started manually", batteryPercent: 90),
        PersistedSessionEvent(date: end, began: false, reason: "Stopped manually", batteryPercent: 85),
    ]
    let stats = AwakeStatsAggregator.summarize(
        events: events, now: end, dayCount: 2, calendar: cal)
    #expect(stats.totalHeldSeconds == 2 * 3600)
    #expect(stats.days.count == 2)
    #expect(stats.days[0].heldSeconds == 3600) // 23:00-00:00
    #expect(stats.days[1].heldSeconds == 3600) // 00:00-01:00
    #expect(stats.days[0].batteryConsumed == 5)
}

@Test func awakeStatsOpenSessionCountsThroughNow() {
    let start = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_000 + 600)
    let stats = AwakeStatsAggregator.summarize(
        events: [PersistedSessionEvent(date: start, began: true, reason: "t")],
        now: now,
        dayCount: 1,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(stats.totalHeldSeconds == 600)
}
