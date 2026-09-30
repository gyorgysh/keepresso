import SwiftUI
import Combine
import KeepressoCore

/// The icon shown in the system menu bar: the brand cup as a template image,
/// filled with steam while brewing, an outline while idle (``MenuBarIcon``),
/// so the bar matches the app icon and the website mark instead of the stock
/// `cup.and.saucer` SF Symbol.
///
/// The label stays static by design: a `MenuBarExtra` label is snapshotted to
/// a template image, so a Canvas renders blank, `TimelineView` freezes the
/// app, and SwiftUI animations don't run there. State reads through the fill
/// and the steam, not motion. The optional countdown text next to the icon
/// updates via a plain `Timer.publish` tick for the same reason.
struct MenuBarLabel: View {
    @Bindable var session: SessionController
    /// Whether to show remaining time next to the icon for a timed session
    /// (Preferences ▸ General). Off by default.
    var showCountdown: Bool = false
    /// Applied only when customization is explicitly enabled.
    var presentation: MenuLayout? = nil

    /// Drives the countdown text once a second. `remaining` is a computed
    /// property (reads the live clock) that Observation doesn't track, so
    /// something has to force a periodic redraw, `TimelineView` was tried
    /// first (matching the doc comment's warning below) and froze the app, so
    /// this mirrors `MenuBarContent`'s already-working `Timer.publish` tick.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var remainingText = ""
    @State private var customText = ""

    var body: some View {
        Group {
            if let presentation {
                customLabel(presentation)
            } else {
                standardLabel
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var standardLabel: some View {
        HStack(spacing: 3) {
            // One same-size image for every state, battery pause included:
            // the status item never widens for a conditionally added second
            // image (it just clips it), so state changes swap this single
            // image instead. Added text does relayout, which is why the
            // countdown below works as a separate view.
            Image(nsImage: icon)
            if showCountdown, session.isActive, session.remaining != nil {
                Text(remainingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .onReceive(tick) { _ in remainingText = Self.format(session.remaining) }
                    .onAppear { remainingText = Self.format(session.remaining) }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func customLabel(_ layout: MenuLayout) -> some View {
        HStack(spacing: 3) {
            if layout.showMenuBarIcon { Image(nsImage: icon) }
            if layout.menuBarTextStyle != .iconOnly {
                if layout.menuBarTextStyle != .existing || (showCountdown && session.isActive && session.remaining != nil) {
                    Text(customText.isEmpty ? L("Idle") : customText).font(.caption.monospacedDigit()).foregroundStyle(.primary)
                        .onReceive(tick) { _ in refreshCustomText(layout) }
                        .onAppear { refreshCustomText(layout) }
                        .onChange(of: layout) { _, new in refreshCustomText(new) }
                        .onChange(of: session.isActive) { _, _ in refreshCustomText(layout) }
                }
            }
        }
    }

    private func refreshCustomText(_ layout: MenuLayout) {
        let status = session.pausedByBattery || session.pausedByThermal
            ? L("Paused") : (session.isActive ? L("Brewing") : L("Idle"))
        switch layout.menuBarTextStyle {
        case .existing: customText = Self.format(session.remaining)
        case .iconOnly: customText = ""
        case .remaining: customText = session.remaining.map { Self.format($0) } ?? status
        case .elapsed: customText = session.isActive ? Self.format(session.elapsed) : status
        case .endTime:
            customText = session.remaining.map { Date().addingTimeInterval($0).formatted(date: .omitted, time: .shortened) } ?? status
        case .status: customText = status
        }
    }

    private var icon: NSImage {
        if session.pausedByBattery { return MenuBarIcon.pausedLowBattery }
        return session.isActive ? MenuBarIcon.brewing : MenuBarIcon.idle
    }

    private var accessibilityText: String {
        if session.pausedByBattery { return L("Keepresso: paused, battery low") }
        return session.isActive ? L("Keepresso: brewing") : L("Keepresso: idle")
    }

    /// "12:03" for under an hour, "1:02:03" once it reaches an hour.
    static func format(_ interval: TimeInterval?) -> String {
        let raw = interval ?? 0
        // Saturate rather than trap: `Int(_:)` faults on a value past Int.max,
        // and this formats whatever duration a settings blob produced.
        let capped = raw.isFinite ? min(max(0, raw), SessionMode.maxTimedMinutes * 60) : 0
        let total = Int(capped.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? L("%d:%02d:%02d", hours, minutes, seconds)
            : L("%d:%02d", minutes, seconds)
    }
}
