import SwiftUI
import KeepressoCore

/// The one-row stand-in for the thermal section's helper-only group (fan
/// boost, fan test, closed-display lift) while the helper isn't installed:
/// says what's locked and why, and carries the unlock action itself, so
/// nobody has to scroll up hunting for the helper section. Flips to the
/// approval step once an install is under way, and surfaces an install
/// error inline instead of failing into silence.
struct ThermalHelperLockedRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if model.helper.awaitingApproval {
                Image(systemName: "hourglass")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("One step left, in System Settings: allow Keepresso under Login Items, and these unlock by themselves.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open Login Items") { model.helper.openApprovalSettings() }
            } else {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: lockedText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Install Helper…") { model.installHelper() }
            }
        }
        if let error = model.helper.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var lockedText: String {
        model.machineHasFans
            ? L("Boosting fans and switching off closed-display mode during a heat pause need the administrator helper. Watching temperatures and pausing work without it. Installing asks for your approval once, in System Settings.")
            : L("Switching off closed-display mode during a heat pause needs the administrator helper. Watching temperatures and pausing work without it. Installing asks for your approval once, in System Settings.")
    }
}

/// The "Test Fans" rows in Preferences ▸ General ▸ Thermal: a short
/// supervised run through three boost levels (50, 70, 90 percent) with
/// readings at each, then a plain verdict. The point is peace of mind:
/// prove the whole fan path (helper, firmware, readings) once, so "Boost
/// fans first" can be left on trusted. Only shown with the helper installed;
/// ``ThermalHelperLockedRow`` covers the section otherwise.
struct FanTestRows: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            switch model.fanDryRun.phase {
            case .running(let percent):
                ProgressView()
                    .controlSize(.small)
                Text(runningLabel(percent))
                Spacer(minLength: 8)
                Button("Stop") { model.fanDryRun.cancel() }
            default:
                // The one text slot either invites the test or names the
                // exact reason it can't run right now; a silently disabled
                // control explains nothing.
                Text(verbatim: gateText)
                    .foregroundStyle(model.fanTestGate == .ready ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Test Fans") { model.fanDryRun.start() }
                    .disabled(!model.canRunFanDryRun)
                    .help(gateText)
            }
        }
        switch model.fanDryRun.phase {
        case .finished(let report):
            verdictRows(report)
        case .cancelled:
            Label(L("Test stopped. Fan control is back with the system."), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// What the idle row says, per gate state. The helper-missing states are
    /// covered by ``ThermalHelperLockedRow`` before this view ever shows, so
    /// their texts here are just safe fallbacks.
    private var gateText: String {
        switch model.fanTestGate {
        case .ready:
            L("Run a quick check: the fans step through three boost levels for about 12 seconds, with readings at each, then control goes back to the system.")
        case .needsHelper, .awaitingApproval:
            L("The fan test needs the administrator helper.")
        case .helperUpdating:
            L("The helper is updating itself to this version of Keepresso (no password needed). Fan boost and this test unlock when it finishes, usually under a minute.")
        case .boostActive:
            L("The fans are boosted for heat right now, so the test stays off until readings recover.")
        }
    }

    private func runningLabel(_ percent: Int?) -> String {
        guard let percent else { return L("Reading the fans…") }
        return L("Boosting fans to %d%% and reading back…", percent)
    }

    @ViewBuilder
    private func verdictRows(_ report: FanDryRunReport) -> some View {
        switch report.verdict {
        case .allGood:
            Label {
                Text(verbatim: [
                    L("All good. Every fan followed the boost, and control is back with the system."),
                    fanSummary(report),
                    temperatureSummary(report)
                ].compactMap { $0 }.joined(separator: " "))
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        case .fansDidNotRespond:
            Label {
                Text(verbatim: [
                    L("The fans didn't follow the boost, so this Mac's firmware likely refuses manual fan control. The rest of the thermal safety net still works, the boost stage will just be skipped."),
                    fanSummary(report)
                ].compactMap { $0 }.joined(separator: " "))
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        case .helperUnavailable:
            Label(
                L("The administrator helper didn't accept fan control. Check its status in the section above, then run the test again."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case .noFans:
            Label(L("No fans were found to test."), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Fan 1: 1204 → 5510 rpm (max 5927). Fan 2: …" for however many fans
    /// produced readings.
    private func fanSummary(_ report: FanDryRunReport) -> String? {
        guard let last = report.steps.last else { return nil }
        let parts = (0..<report.fanCount).compactMap { fan -> String? in
            guard let final = last.rpm.indices.contains(fan) ? last.rpm[fan] : nil else { return nil }
            let from = report.baselineRPM.indices.contains(fan) ? report.baselineRPM[fan] : nil
            let fromText = from.map { String(Int($0.rounded())) } ?? "?"
            var line = L("Fan %d: %@ → %@ rpm", fan + 1, fromText, String(Int(final.rounded())))
            if let max = report.maxRPM.indices.contains(fan) ? report.maxRPM[fan] : nil {
                line += " " + L("(max %@)", String(Int(max.rounded())))
            }
            return line + "."
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func temperatureSummary(_ report: FanDryRunReport) -> String? {
        report.hottestCelsius.map {
            L("Hottest sensor during the test: %@.", String(format: "%.0f °C", $0))
        }
    }
}
