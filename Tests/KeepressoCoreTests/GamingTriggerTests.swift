import Testing
import Foundation
@testable import KeepressoCore

private final class FakeGamingMonitor: GamingMonitoring {
    var snapshot: GamingSnapshot
    init(bundleID: String? = nil, category: String? = nil) {
        snapshot = GamingSnapshot(frontmostBundleID: bundleID, frontmostCategoryType: category)
    }
    var current: GamingSnapshot { snapshot }
}

@Test func gamingTriggerMatchesGamesCategoryAndSubcategories() {
    #expect(GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.example.game",
        frontmostCategoryType: "public.app-category.games"
    )))
    #expect(GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.example.racer",
        frontmostCategoryType: "public.app-category.racing-games"
    )))
    #expect(!GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.example.editor",
        frontmostCategoryType: "public.app-category.productivity"
    )))
    // A `-games` suffix outside the app-category namespace must not match.
    #expect(!GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.example.odd",
        frontmostCategoryType: "com.example.category.games"
    )))
    #expect(!GamingTrigger.isGame(GamingSnapshot(frontmostBundleID: "com.example.plain")))
    #expect(!GamingTrigger.isGame(GamingSnapshot()))
}

@Test func gamingTriggerMatchesCloudGamingClientsWithoutCategory() {
    for id in GamingTrigger.cloudGamingBundleIDs {
        #expect(GamingTrigger.isGame(GamingSnapshot(frontmostBundleID: id)))
    }
}

@Test func gamingTriggerMatchesSteamGamesByLibraryPath() {
    // Steam games often skip the category declaration (ports, Wine
    // wrappers), but they all run from a steamapps library folder.
    #expect(GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.example.port",
        frontmostBundlePath: "/Users/g/Library/Application Support/Steam/steamapps/common/Hades/Hades.app"
    )))
    // Custom library volumes count too.
    #expect(GamingTrigger.isGame(GamingSnapshot(
        frontmostBundlePath: "/Volumes/Games/SteamLibrary/steamapps/common/Factorio/factorio.app"
    )))
    // Steam itself (the launcher, storefront) is not a game.
    #expect(!GamingTrigger.isGame(GamingSnapshot(
        frontmostBundleID: "com.valvesoftware.steam",
        frontmostBundlePath: "/Applications/Steam.app"
    )))
}

@Test func gamingTriggerFollowsFrontmostState() {
    let monitor = FakeGamingMonitor(bundleID: "com.example.game", category: "public.app-category.games")
    let trigger = GamingTrigger(monitor: monitor)
    #expect(trigger.isSatisfied())

    monitor.snapshot = GamingSnapshot(frontmostBundleID: "com.apple.finder")
    #expect(!trigger.isSatisfied())
}

@Test func gamingRuleLabelAndCodableRoundTrip() throws {
    let rule = TriggerRule.gaming
    #expect(rule.label == "Playing a game")
    let data = try JSONEncoder().encode([rule])
    #expect(try JSONDecoder().decode([TriggerRule].self, from: data) == [rule])
}

@Test func factoryWrapsGamingTriggerInReleaseGrace() {
    // Alt-tabbing to Discord or a walkthrough must not drop the session;
    // only staying away past the grace does.
    let monitor = FakeGamingMonitor(bundleID: "com.nvidia.gfnpc.mall")
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let factory = TriggerFactory(gaming: monitor, now: { now })
    let engine = factory.makeEngine(from: RuleSet(rules: [.gaming]))
    engine.tick()
    #expect(engine.isSatisfied())

    monitor.snapshot = GamingSnapshot(frontmostBundleID: "com.hnc.Discord")
    now.addTimeInterval(GamingTrigger.releaseGrace - 1)
    engine.tick()
    #expect(engine.isSatisfied())

    now.addTimeInterval(2)
    engine.tick()
    #expect(!engine.isSatisfied())
}

@Test func gamingMonitorCachesWithinTTLAndReprobesAfter() {
    var probes = 0
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let monitor = WorkspaceGamingMonitor(ttl: 3, now: { now }) {
        probes += 1
        return GamingSnapshot(frontmostBundleID: "com.example.game")
    }

    #expect(monitor.current.frontmostBundleID == "com.example.game")
    now.addTimeInterval(2)
    _ = monitor.current
    #expect(probes == 1)

    now.addTimeInterval(2)
    _ = monitor.current
    #expect(probes == 2)
}
