import AppIntents
import SwiftUI
import WidgetKit
import KeepressoCore

/// The widget extension's entry point: the desktop status widget everywhere
/// (macOS 14+), plus the Control Center toggle where it exists (macOS 26+).
@main
struct KeepressoWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeepAwakeWidget()
        if #available(macOS 26.0, *) {
            KeepressoControls().body
        }
    }
}

/// The macOS 26 controls, split into their own bundle so the main bundle can
/// keep a macOS 14 floor.
@available(macOS 26.0, *)
struct KeepressoControls: WidgetBundle {
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
    /// A friendly preview for the widget gallery: mid-brew with time left.
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
        if !keepressoAppIsRunning() {
            state.isActive = false
            state.endsAt = nil
        } else if let endsAt = state.endsAt, endsAt <= .now {
            state.isActive = false
            state.endsAt = nil
        }
        let entry = SessionEntry(date: .now, state: state)
        let policy: TimelineReloadPolicy =
            state.isActive ? state.endsAt.map { .after($0) } ?? .never : .never
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
        .configurationDisplayName("Keep Awake")
        .description("See and control whether Keepresso is keeping the Mac awake.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The brand's caramel palette (matching `Theme.keepressoBrew`), fixed rather
/// than appearance-driven because the widget paints its own background.
private enum WidgetPalette {
    static let brew = Color(red: 232 / 255, green: 163 / 255, blue: 92 / 255)
    static let steam = Color(red: 217 / 255, green: 122 / 255, blue: 74 / 255)
    static let roast = Color(red: 43 / 255, green: 26 / 255, blue: 14 / 255)
    static let idleRoast = Color(red: 32 / 255, green: 26 / 255, blue: 22 / 255)
    static let cream = Color(red: 248 / 255, green: 236 / 255, blue: 221 / 255)
    /// Secondary text and idle strokes. Fixed like the background: adaptive
    /// styles (.primary/.secondary) resolve to near-black in light mode and
    /// vanish against the dark roast.
    static let creamDim = cream.opacity(0.6)
}

/// Deep roast with a caramel glow while brewing; flat and dim while idle.
private struct WidgetBackground: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            LinearGradient(
                colors: [WidgetPalette.roast, WidgetPalette.steam.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            WidgetPalette.idleRoast
        }
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
                BrandCupBadge(active: state.isActive)
                    .frame(width: 44, height: 44)
                Text(state.isActive ? "Brewing" : "Off")
                    .font(.headline)
                    .foregroundStyle(state.isActive ? WidgetPalette.cream : WidgetPalette.creamDim)
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
                    BrandCupBadge(active: state.isActive)
                        .frame(width: 24, height: 24)
                    Text("Keepresso")
                        .font(.headline)
                        .foregroundStyle(state.isActive ? WidgetPalette.cream : WidgetPalette.cream.opacity(0.9))
                }
                Text(state.isActive ? "Keeping the Mac awake" : "The Mac can sleep")
                    .font(.subheadline)
                    .foregroundStyle(WidgetPalette.creamDim)
                countdown
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Button(intent: ToggleKeepAwakeWidgetIntent()) {
                    Label(state.isActive ? "Stop" : "Start", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WidgetPalette.brew)

                if state.triggersEnabled {
                    Button(intent: SetTriggersPausedWidgetIntent(paused: !state.triggersPaused)) {
                        Label(
                            state.triggersPaused ? "Resume Triggers" : "Pause Triggers",
                            systemImage: state.triggersPaused ? "play.fill" : "pause.fill"
                        )
                        // Explicit brand color: the bordered style's label
                        // ignored .tint in widget rendering and came out
                        // system blue.
                        .foregroundStyle(WidgetPalette.brew)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(WidgetPalette.brew)
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
                .foregroundStyle(WidgetPalette.cream.opacity(0.85))
        }
    }
}

/// The real brand mark, drawn from the shared ``BrandCupMark`` geometry:
/// filled caramel cup with steam while brewing, a quiet outline while idle.
private struct BrandCupBadge: View {
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let ink = active ? BrandCupMark.fullInk : BrandCupMark.cupInk
            let scale = min(geo.size.width / ink.width, geo.size.height / ink.height)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -ink.minX, y: -ink.minY)

            ZStack {
                if active {
                    Path(BrandCupMark.cup()).applying(transform)
                        .fill(WidgetPalette.brew)
                    Path(BrandCupMark.crema()).applying(transform)
                        .fill(.black)
                        .blendMode(.destinationOut)
                    Path(BrandCupMark.handle()).applying(transform)
                        .stroke(WidgetPalette.brew, style: .init(
                            lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                    ForEach(Array(BrandCupMark.steamWisps().enumerated()), id: \.offset) { _, wisp in
                        Path(wisp).applying(transform)
                            .stroke(WidgetPalette.steam, style: .init(
                                lineWidth: BrandCupMark.steamWidth * scale, lineCap: .round))
                    }
                } else {
                    Path(BrandCupMark.cupAndHandle()).applying(transform)
                        .stroke(WidgetPalette.creamDim, style: .init(
                            lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                }
                Path(BrandCupMark.saucer()).applying(transform)
                    .stroke(active ? WidgetPalette.brew : WidgetPalette.creamDim, style: .init(
                        lineWidth: BrandCupMark.saucerWidth * scale, lineCap: .round))
            }
            .compositingGroup() // confine destinationOut to the glyph's layers
        }
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
                // The brand cup as a custom symbol (generated by
                // scripts/make-symbol.swift); controls only render symbols.
                Label(on ? "Brewing" : "Off", image: "keepresso.cup")
            }
            .tint(WidgetPalette.brew)
        }
        .displayName("Keep Awake")
        .description("Start or stop keeping the Mac awake.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            keepressoAppIsRunning() && currentSharedState()?.isActive == true
        }
    }
}
