import AppIntents
import SwiftUI
import WidgetKit
import PervigilCore

/// Localized-string lookup against the widget extension's own bundle. The
/// appex has never been localized before; this mirrors the app's `L(_:)` in
/// `Pervigil/Localization.swift`, kept file-private and inline here since the
/// Xcode project's file list is generated from `project.yml`, so adding a
/// sibling file isn't an option.
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// The widget extension's entry point: the desktop status widget everywhere
/// (macOS 14+), plus the Control Center toggle where it exists (macOS 26+).
@main
struct PervigilWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeepAwakeWidget()
        if #available(macOS 26.0, *) {
            PervigilControls().body
        }
    }
}

/// The macOS 26 controls, split into their own bundle so the main bundle can
/// keep a macOS 14 floor.
@available(macOS 26.0, *)
struct PervigilControls: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
    }
}

// MARK: - Shared plumbing
//
// The widget views run in the sandboxed appex process, which can't touch the
// app's memory, so state rides the ``WidgetBridge`` App Group channel: the
// widgets read what the app mirrors on every change. The button/toggle intents
// live in `WidgetIntents.swift`, shared with the app target so
// `openAppWhenRun` can launch a quit app before the command is consumed.

// MARK: - Desktop widget

struct SessionEntry: TimelineEntry {
    let date: Date
    let state: SharedSessionState
}

struct SessionProvider: TimelineProvider {
    /// A friendly preview for the widget gallery: a running session with time left.
    func placeholder(in context: Context) -> SessionEntry {
        SessionEntry(
            date: .now,
            state: SharedSessionState(isActive: true, endsAt: .now.addingTimeInterval(25 * 60))
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(SessionEntry(date: .now, state: currentSharedState() ?? SharedSessionState(isActive: false)))
        }
    }

    /// One entry reflecting the shared state; the app reloads the timeline on
    /// every change, so the only self-scheduled refresh is a timed session's
    /// end (in case the app isn't there to announce it).
    ///
    /// The stored state is only trusted while the app is actually running: a
    /// crash or force quit skips the clean-quit "off" write, and the session's
    /// assertions died with the process, so rendering the stored "Brewing"
    /// would lie indefinitely. A deadline already in the past is the same
    /// story (the timed session provably ended), and rendering it inactive
    /// also avoids scheduling a reload loop one second in the future forever.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionEntry>) -> Void) {
        var state = currentSharedState() ?? SharedSessionState(isActive: false)
        if !pervigilAppIsRunning() {
            state.isActive = false
            state.endsAt = nil
        } else if let endsAt = state.endsAt, endsAt <= .now {
            state.isActive = false
            state.endsAt = nil
        }
        let entry = SessionEntry(date: .now, state: state)
        // The app can die without writing the "off" state, so a live session
        // re-checks periodically and lets `pervigilAppIsRunning()` flip it
        // rather than rendering "Brewing" forever. Hourly, not sooner: this
        // backstop fires only when the app is dead (live changes push their
        // own reloads), and a 15-minute cadence would burn through WidgetKit's
        // daily budget overnight. A timed session still refreshes at its end.
        let policy: TimelineReloadPolicy
        if state.isActive, let endsAt = state.endsAt {
            policy = .after(min(endsAt, .now.addingTimeInterval(60 * 60)))
        } else if state.isActive {
            policy = .after(.now.addingTimeInterval(60 * 60))
        } else {
            policy = .never
        }
        completion(Timeline(entries: [entry], policy: policy))
    }
}

struct KeepAwakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.statusWidgetKind, provider: SessionProvider()) { entry in
            KeepAwakeWidgetView(state: entry.state)
                .containerBackground(for: .widget) {
                    WidgetBackground(isActive: entry.state.isActive)
                }
        }
        .configurationDisplayName(L("Keep Awake"))
        .description(Text(L("See and control whether Pervigil is keeping the Mac awake.")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The brand palette (matching `Theme.pervigilAccent` and the mark's
/// gradient), fixed rather than appearance-driven because the widget paints
/// its own background: everything sits on the brand's dark colorway.
private enum WidgetPalette {
    /// The accent, the dark-mode Pervigil blue (#2D8EF9).
    static let accent = Color(red: 45 / 255, green: 142 / 255, blue: 249 / 255)
    /// The mark's gradient, #6EAFF6 at the top to #007AFF at the bottom.
    static let markTop = Color(red: 110 / 255, green: 175 / 255, blue: 246 / 255)
    static let markBottom = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
    /// The dark colorway's background, #171717 to #010101.
    static let surfaceTop = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let surfaceBottom = Color(red: 1 / 255, green: 1 / 255, blue: 1 / 255)
    static let ink = Color.white
    /// Secondary text and the idle outline. Fixed like the background:
    /// adaptive styles (.primary/.secondary) resolve to near-black in light
    /// mode and vanish against the dark surface.
    static let inkDim = ink.opacity(0.6)
}

/// The dark surface with a soft blue glow rising from the bottom while a
/// session runs; the plain dark gradient while idle.
private struct WidgetBackground: View {
    let isActive: Bool

    var body: some View {
        LinearGradient(
            colors: isActive
                ? [WidgetPalette.surfaceTop, WidgetPalette.accent.opacity(0.45)]
                : [WidgetPalette.surfaceTop, WidgetPalette.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct KeepAwakeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let state: SharedSessionState

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    /// Small: the whole tile is the toggle.
    private var small: some View {
        Button(intent: ToggleKeepAwakeWidgetIntent()) {
            VStack(spacing: 6) {
                BrandMarkBadge(active: state.isActive)
                    .frame(width: 44, height: 44)
                Text(state.isActive ? L("Awake") : L("Off"))
                    .font(.headline)
                    .foregroundStyle(state.isActive ? WidgetPalette.ink : WidgetPalette.inkDim)
                countdown
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Medium: status on the left, actions on the right.
    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    BrandMarkBadge(active: state.isActive)
                        .frame(width: 24, height: 24)
                    Text("Pervigil")
                        .font(.headline)
                        .foregroundStyle(state.isActive ? WidgetPalette.ink : WidgetPalette.ink.opacity(0.9))
                }
                Text(state.isActive ? L("Keeping the Mac awake") : L("The Mac can sleep"))
                    .font(.subheadline)
                    .foregroundStyle(WidgetPalette.inkDim)
                countdown
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Button(intent: ToggleKeepAwakeWidgetIntent()) {
                    Label(state.isActive ? L("Stop") : L("Start"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WidgetPalette.accent)

                if state.triggersEnabled {
                    Button(intent: SetTriggersPausedWidgetIntent(paused: !state.triggersPaused)) {
                        Label(
                            state.triggersPaused ? L("Resume Triggers") : L("Pause Triggers"),
                            systemImage: state.triggersPaused ? "play.fill" : "pause.fill"
                        )
                        // Explicit brand color: the bordered style's label
                        // ignored .tint in widget rendering and came out
                        // system blue.
                        .foregroundStyle(WidgetPalette.accent)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(WidgetPalette.accent)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Live countdown for timed sessions; nothing for indefinite ones.
    @ViewBuilder
    private var countdown: some View {
        if state.isActive, let endsAt = state.endsAt, endsAt > .now {
            Text(timerInterval: Date.now ... endsAt, countsDown: true)
                .font(.caption.monospacedDigit())
                .foregroundStyle(WidgetPalette.ink.opacity(0.85))
        }
    }
}

/// The brand mark, drawn from the shared ``BrandMark`` geometry: solid in
/// the brand gradient while a session runs, a quiet outline while idle (the
/// same states as the menu bar icon).
private struct BrandMarkBadge: View {
    var active: Bool

    private static let eoFill = FillStyle(eoFill: true)

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let mark = Path(BrandMark.path(fitting: rect))
            if active {
                mark.fill(
                    LinearGradient(colors: [WidgetPalette.markTop, WidgetPalette.markBottom],
                                   startPoint: .top, endPoint: .bottom),
                    style: Self.eoFill)
            } else {
                // An inner stroke (stroked at twice the width, clipped to
                // the mark), so the outline keeps the solid mark's footprint.
                let markHeight = min(geo.size.height, geo.size.width / BrandMark.aspectRatio)
                mark.stroke(WidgetPalette.inkDim, lineWidth: max(1, markHeight * 0.08) * 2)
                    .clipShape(mark, style: Self.eoFill)
            }
        }
        .aspectRatio(BrandMark.aspectRatio, contentMode: .fit)
    }
}

// MARK: - Control Center toggle (macOS 26+)

@available(macOS 26.0, *)
struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetBridge.controlKind, provider: Provider()) { isOn in
            ControlWidgetToggle(
                "Keep Awake",
                isOn: isOn,
                action: SetKeepAwakeControlIntent()
            ) { on in
                // The brand mark as a custom symbol (generated by
                // scripts/make-symbol.swift); controls only render symbols.
                Label(on ? L("Awake") : L("Off"), image: "pervigil.mark")
            }
            .tint(WidgetPalette.accent)
        }
        .displayName("Keep Awake")
        .description("Start or stop keeping the Mac awake.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            pervigilAppIsRunning() && currentSharedState()?.isActive == true
        }
    }
}
