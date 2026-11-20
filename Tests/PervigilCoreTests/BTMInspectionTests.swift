import Testing
import Foundation
@testable import PervigilCore

private let appID = "io.github.bubb4rd.pervigil"
private let helperLabel = "io.github.bubb4rd.pervigil.helper"

/// Trimmed from a real `sfltool dumpbtm` on the machine that hit the bug:
/// the installed app enabled, the daemon disabled, a stale Trash copy in
/// another store, and unrelated third-party records.
private let wedgedDump = """
 #3:
                 UUID: 4AC3BA7E-5573-4830-801E-AEF660150817
                 Name: Pervigil
       Developer Name: pueev OU
      Team Identifier: 8SY98BT8RV
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: 2.io.github.bubb4rd.pervigil
                  URL: file:///Applications/Pervigil.app/
           Generation: 29801137218
    Bundle Identifier: io.github.bubb4rd.pervigil
  Embedded Item Identifiers:
    #1: 16.io.github.bubb4rd.pervigil.helper

 #4:
                 UUID: 19D47F63-8082-4446-A9C1-AC624DD4F794
                 Name: pervigil-helper
       Developer Name: (null)
                 Type: daemon (0x10)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: 16.io.github.bubb4rd.pervigil.helper
                  URL: Contents/Library/LaunchDaemons/io.github.bubb4rd.pervigil.helper.plist
      Executable Path: Contents/MacOS/pervigil-helper
           Generation: 2
    Parent Identifier: 2.io.github.bubb4rd.pervigil

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
                 Name: Pervigil
       Developer Name: pueev OU
      Team Identifier: 8SY98BT8RV
                 Type: app (0x2)
          Disposition: [disabled, allowed, notified] (0xa)
           Identifier: 2.io.github.bubb4rd.pervigil
                  URL: file:///Users/gyorgy/.Trash/Pervigil%2016.43.20.app/
           Generation: 28
    Bundle Identifier: io.github.bubb4rd.pervigil
"""

@Test func findingsSpotTheDisabledDaemonAndTheTrashCopy() {
    let findings = BTMInspection.findings(
        inDump: wedgedDump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .disabled)
    #expect(findings.staleCopyPaths == ["/Users/gyorgy/.Trash/Pervigil 16.43.20.app"])
}

@Test func findingsIgnoreOtherAppsRecords() {
    // Logi's disabled app record must not count as a Pervigil stale copy,
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
                     Name: pervigil-helper
                     Type: daemon (0x10)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.io.github.bubb4rd.pervigil.helper
    """
    let findings = BTMInspection.findings(
        inDump: dump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .enabled)
}

@Test func aDisallowedTombstoneIsReportedAsSuch() {
    let dump = """
     #1:
                     Name: pervigil-helper
                     Type: daemon (0x10)
              Disposition: [disabled, disallowed, not notified] (0)
               Identifier: 16.io.github.bubb4rd.pervigil.helper
    """
    let findings = BTMInspection.findings(
        inDump: dump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.daemonState == .disallowed)
}

@Test func embeddedItemListsDoNotStartNewRecords() {
    let records = BTMInspection.parseRecords(wedgedDump)
    // 4 records: the `#1: 16.sh...` embedded line stays inside Pervigil's.
    #expect(records.count == 4)
    #expect(records[0].fields["Name"] == "Pervigil")
    #expect(records[0].identifier == "2.io.github.bubb4rd.pervigil")
}

@Test func dispositionTokensAreMatchedExactly() {
    // "disabled" contains "enabled" as a substring; the parser must not fall
    // for it.
    let records = BTMInspection.parseRecords(wedgedDump)
    let daemon = records.first { $0.identifier == "16.io.github.bubb4rd.pervigil.helper" }
    #expect(daemon?.isEnabled == false)
    #expect(daemon?.isDisallowed == false)
    let app = records.first { $0.url == "file:///Applications/Pervigil.app/" }
    #expect(app?.isEnabled == true)
}

@Test func trashPathsArePercentDecoded() {
    let findings = BTMInspection.findings(
        inDump: wedgedDump, bundleIdentifier: appID, helperLabel: helperLabel
    )
    #expect(findings.staleCopyPaths.first?.contains("Pervigil 16.43.20.app") == true)
}
