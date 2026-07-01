import SwiftUI
import KeepressoCore

/// The icon shown in the system menu bar: a filled cup while brewing, an outline
/// cup while idle.
///
/// While brewing it animates with a `.symbolEffect` "brewing" shimmer. We use an
/// SF Symbol rather than a custom `Canvas`/`TimelineView`: a `MenuBarExtra` label
/// is snapshotted to a template image, so a Canvas renders blank, `TimelineView`
/// freezes the app, and arbitrary SwiftUI animations don't run — `.symbolEffect`
/// is the one animation the menu bar honours. The optional countdown text next
/// to it updates via a plain `Timer.publish` tick for the same reason.
struct MenuBarLabel: View {
    @Bindable var session: SessionController
    /// Whether to show remaining time next to the icon for a timed session
    /// (Preferences ▸ General). Off by default.
    var showCountdown: Bool = false

    /// Drives the countdown text once a second. `remaining` is a computed
    /// property (reads the live clock) that Observation doesn't track, so
    /// something has to force a periodic redraw — `TimelineView` was tried
    /// first (matching the doc comment's warning below) and froze the app, so
    /// this mirrors `MenuBarContent`'s already-working `Timer.publish` tick.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var remainingText = ""

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: session.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeating,
                    isActive: session.isActive
                )
            if showCountdown, session.isActive, session.remaining != nil {
                Text(remainingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .onReceive(tick) { _ in remainingText = Self.format(session.remaining) }
                    .onAppear { remainingText = Self.format(session.remaining) }
            }
        }
        .accessibilityLabel(session.isActive ? "Keepresso: brewing" : "Keepresso: idle")
    }

    /// "12:03" for under an hour, "1:02:03" once it reaches an hour.
    static func format(_ interval: TimeInterval?) -> String {
        let total = max(0, Int((interval ?? 0).rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
