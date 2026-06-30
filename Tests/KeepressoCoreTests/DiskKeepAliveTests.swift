import Testing
import Foundation
@testable import KeepressoCore

/// In-memory toucher that records every write and can be told to fail.
private final class FakeToucher: DiskTouching {
    private(set) var touched: [URL] = []
    var shouldFail = false
    func touch(at url: URL) -> Bool {
        touched.append(url)
        return !shouldFail
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private let dir = URL(fileURLWithPath: "/Volumes/NAS/share")

@MainActor
private func makeController() -> (DiskKeepAliveController, FakeToucher, Clock) {
    let toucher = FakeToucher()
    return (DiskKeepAliveController(toucher: toucher), toucher, Clock())
}

@MainActor
@Test func disabledNeverTouches() {
    let (controller, toucher, clock) = makeController()
    clock.advance(60 * 60)
    controller.tick(now: clock.now) // config nil
    #expect(toucher.touched.isEmpty)
}

@MainActor
@Test func touchesImmediatelyWhenEnabled() {
    let (controller, toucher, clock) = makeController()
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 300)
    controller.tick(now: clock.now)
    #expect(toucher.touched == [dir.appendingPathComponent(".keepresso-keepalive")])
}

@MainActor
@Test func throttlesWithinInterval() {
    let (controller, toucher, clock) = makeController()
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 300)
    controller.tick(now: clock.now) // first touch

    clock.advance(299)
    controller.tick(now: clock.now)
    #expect(toucher.touched.count == 1) // still inside the interval

    clock.advance(2) // 301s since the first touch
    controller.tick(now: clock.now)
    #expect(toucher.touched.count == 2) // interval elapsed → touch again
}

@MainActor
@Test func changingConfigTouchesImmediately() {
    let (controller, toucher, clock) = makeController()
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 300)
    controller.tick(now: clock.now)
    #expect(toucher.touched.count == 1)

    clock.advance(10)
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 600) // changed
    controller.tick(now: clock.now)
    #expect(toucher.touched.count == 2) // throttle reset by the new config
}

@MainActor
@Test func recordsTouchFailure() {
    let (controller, toucher, clock) = makeController()
    toucher.shouldFail = true
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 300)
    controller.tick(now: clock.now)
    #expect(controller.lastTouchFailed)
    #expect(controller.lastTouch != nil) // attempt still timestamped, so we back off
}

@MainActor
@Test func disablingStopsTouching() {
    let (controller, toucher, clock) = makeController()
    controller.config = DiskKeepAliveConfig(directory: dir, interval: 300)
    controller.tick(now: clock.now)
    controller.config = nil
    clock.advance(10 * 60)
    controller.tick(now: clock.now)
    #expect(toucher.touched.count == 1) // no further touches once off
}

@Test func configEncodesRoundTrip() throws {
    let config = DiskKeepAliveConfig(directory: dir, interval: 420)
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(DiskKeepAliveConfig.self, from: data)
    #expect(decoded == config)
}
