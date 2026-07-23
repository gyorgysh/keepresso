import Testing
import Foundation
@testable import KeepressoCore

// MARK: - Parsers (fixtures captured from a real live download)

@Test func acfStateFlagsParse() {
    let downloading = """
    "AppState"
    {
    \t"appid"\t\t"1030300"
    \t"name"\t\t"Hollow Knight: Silksong"
    \t"StateFlags"\t\t"1026"
    \t"BytesToDownload"\t\t"2265968544"
    }
    """
    #expect(SteamDownload.stateFlags(fromACF: downloading) == 1026)
    #expect(SteamDownload.stateFlags(fromACF: "\"name\" \"x\"") == nil)
    #expect(SteamDownload.stateFlags(fromACF: "") == nil)
}

@Test func stateFlagBitsJudgeDownloadActivity() {
    #expect(SteamDownload.isActive(stateFlags: 1026))  // running (1024 | 2)
    #expect(SteamDownload.isActive(stateFlags: 1024))
    #expect(!SteamDownload.isActive(stateFlags: 2))    // queued, not running
    #expect(!SteamDownload.isActive(stateFlags: 4))    // fully installed
    #expect(!SteamDownload.isActive(stateFlags: 6))    // installed + update required
    #expect(!SteamDownload.isActive(stateFlags: 518))  // paused mid-update
}

@Test func libraryFoldersParse() {
    let vdf = """
    "libraryfolders"
    {
    \t"0"
    \t{
    \t\t"path"\t\t"/Users/someone/Library/Application Support/Steam"
    \t\t"apps"
    \t}
    \t"1"
    \t{
    \t\t"path"\t\t"/Volumes/TB/SteamLibrary"
    \t}
    }
    """
    #expect(SteamDownload.libraryPaths(fromVDF: vdf) == [
        "/Users/someone/Library/Application Support/Steam",
        "/Volumes/TB/SteamLibrary",
    ])
    #expect(SteamDownload.libraryPaths(fromVDF: "").isEmpty)
}

// MARK: - Monitor cache and trigger

private final class FakeSteam: SteamDownloadMonitoring {
    var isDownloading = false
}

@Test func steamMonitorCachesItsProbe() {
    var probes = 0
    var now = Date(timeIntervalSince1970: 6_000_000)
    let monitor = FileSteamDownloadMonitor(ttl: 5, now: { now }) {
        probes += 1
        return true
    }
    #expect(monitor.isDownloading)
    #expect(monitor.isDownloading)
    #expect(probes == 1) // within the TTL
    now.addTimeInterval(6)
    #expect(monitor.isDownloading)
    #expect(probes == 2)
}

@Test func steamTriggerFollowsTheMonitor() {
    let steam = FakeSteam()
    let trigger = SteamDownloadTrigger(monitor: steam)
    #expect(!trigger.isSatisfied())
    steam.isDownloading = true
    #expect(trigger.isSatisfied())
    #expect(!trigger.label.isEmpty)
}

@Test func steamRuleRoundTripsAndJoinsTheGamingPreset() throws {
    let rule = TriggerRule.steamDownload
    let decoded = try JSONDecoder().decode(
        [TriggerRule].self, from: JSONEncoder().encode([rule]))
    #expect(decoded == [rule])
    #expect(rule.requiredPermission == nil)
    let gaming = Preset.builtIns.first { $0.id == "gaming" }
    #expect(gaming?.ruleSet.rules.contains(.steamDownload) == true)
}
