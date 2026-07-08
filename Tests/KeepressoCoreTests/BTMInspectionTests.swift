import Testing
import Foundation
@testable import KeepressoCore

private let appID = "sh.gyorgy.keepresso"
private let helperLabel = "sh.gyorgy.keepresso.helper"

/// Trimmed from a real `sfltool dumpbtm` on the machine that hit the bug:
/// the installed app enabled, the daemon disabled, a stale Trash copy in
/// another store, and unrelated third-party records.
private let wedgedDump = """
 #3:
                 UUID: 4AC3BA7E-5573-4830-801E-AEF660150817
                 Name: Keepresso
       Developer Name: pueev OU
      Team Identifier: 8SY98BT8RV
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: 2.sh.gyorgy.keepresso
                  URL: file:///Applications/Keepresso.app/
           Generation: 29801137218
    Bundle Identifier: sh.gyorgy.keepresso
  Embedded Item Identifiers:
    #1: 16.sh.gyorgy.keepresso.helper

 #4:
                 UUID: 19D47F63-8082-4446-A9C1-AC624DD4F794
                 Name: keepresso-helper
       Developer Name: (null)
                 Type: daemon (0x10)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: 16.sh.gyorgy.keepresso.helper
                  URL: Contents/Library/LaunchDaemons/sh.gyorgy.keepresso.helper.plist
      Executable Path: Contents/MacOS/keepresso-helper
           Generation: 2
    Parent Identifier: 2.sh.gyorgy.keepresso

 #5:
                 UUID: D3F70A0C-4E7C-4FEC-B951-E06A159A911F
                 Name: Logi Options+
      Team Identifier: QED4VVPZWA
                 Type: app (0x2)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: 2.com.logi.cp-dev-mgr
                  URL: file:///Library/Application%20Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/
    Bundle Identifier: com.logi.cp-dev-mgr

 #2:
                 UUID: 06A4F1D4-6A8D-4326-B66D-295451D6339C
                 Name: Keepresso
       Developer Name: pueev OU
      Team Identifier: 8SY98BT8RV
                 Type: app (0x2)
          Disposition: [disabled, allowed, notified] (0xa)
           Identifier: 2.sh.gyorgy.keepresso
                  URL: file:///Users/gyorgy/.Trash/Keepresso%2016.43.20.app/
           Generation: 28
    Bundle Identifier: sh.gyorgy.keepresso
"""

@Test func findingsSpotTheDisabledDaemonAndTheTrashCopy() {
    let findings = BTMInspection.findings(
        inDump: wedgedDump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .disabled)
    #expect(findings.staleCopyPaths == ["/Users/gyorgy/.Trash/Keepresso 16.43.20.app"])
}

@Test func findingsIgnoreOtherAppsRecords() {
    // Logi's disabled app record must not count as a Keepresso stale copy,
    // even if it were in the Trash.
    let findings = BTMInspection.findings(
        inDump: wedgedDump, bundleIdentifier: "com.example.other", helperLabel: "com.example.other.helper"
    )
    #expect(findings.daemonState == .missing)
    #expect(findings.staleCopyPaths.isEmpty)
}

@Test func anEnabledDaemonRecordWinsOverDuplicates() {
    let dump = wedgedDump + """


     #9:
                     Name: keepresso-helper
                     Type: daemon (0x10)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.sh.gyorgy.keepresso.helper
    """
    let findings = BTMInspection.findings(
        inDump: dump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .enabled)
}

@Test func aDisallowedTombstoneIsReportedAsSuch() {
    let dump = """
     #1:
                     Name: keepresso-helper
                     Type: daemon (0x10)
              Disposition: [disabled, disallowed, not notified] (0)
               Identifier: 16.sh.gyorgy.keepresso.helper
    """
    let findings = BTMInspection.findings(
        inDump: dump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .disallowed)
}

@Test func embeddedItemListsDoNotStartNewRecords() {
    let records = BTMInspection.parseRecords(wedgedDump)
    // 4 records: the `#1: 16.sh...` embedded line stays inside Keepresso's.
    #expect(records.count == 4)
    #expect(records[0].fields["Name"] == "Keepresso")
    #expect(records[0].identifier == "2.sh.gyorgy.keepresso")
}

@Test func dispositionTokensAreMatchedExactly() {
    // "disabled" contains "enabled" as a substring; the parser must not fall
    // for it.
    let records = BTMInspection.parseRecords(wedgedDump)
    let daemon = records.first { $0.identifier == "16.sh.gyorgy.keepresso.helper" }
    #expect(daemon?.isEnabled == false)
    #expect(daemon?.isDisallowed == false)
    let app = records.first { $0.url == "file:///Applications/Keepresso.app/" }
    #expect(app?.isEnabled == true)
}

@Test func trashPathsArePercentDecoded() {
    let findings = BTMInspection.findings(
        inDump: wedgedDump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.staleCopyPaths.first?.contains("Keepresso 16.43.20.app") == true)
}
