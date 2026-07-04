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

/// Everything here runs in the sandboxed appex process, which can't touch the
/// app's memory, so state rides the ``WidgetBridge`` App Group channel: the
/// widgets read what the app mirrors on every change, and their intents write
/// a command back and ring the Darwin doorbell (the app reloads the widgets
/// once it has acted, which is what flips the visible state).
private func currentSharedState() -> SharedSessionState? {
    WidgetBridge.groupDefaults().flatMap { WidgetBridge.readState(from: $0) }
}

private func send(_ command: WidgetCommand) {
    guard let defaults = WidgetBridge.groupDefaults() else { return }
    WidgetBridge.writeCommand(command, to: defaults)
    WidgetBridge.postCommandNotification()
}

/// Start/stop from a desktop widget button.
struct ToggleKeepAwakeWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keep Awake"

    func perform() async throws -> some IntentResult {
        send(currentSharedState()?.isActive == true ? .stop : .start)
        return .result()
    }
}

/// Pause or resume trigger gating from the medium widget.
struct SetTriggersPausedWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Triggers"

    @Parameter(title: "Paused")
    var paused: Bool

    init() {}
    init(paused: Bool) {
        self.paused = paused
    }

    func perform() async throws -> some IntentResult {
        send(paused ? .pauseTriggers : .resumeTriggers)
        return .result()
    }
}

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
    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionEntry>) -> Void) {
        let state = currentSharedState() ?? SharedSessionState(isActive: false)
        let entry = SessionEntry(date: .now, state: state)
        let policy: TimelineReloadPolicy =
            state.endsAt.map { .after(max($0, .now.addingTimeInterval(1))) } ?? .never
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
                    .foregroundStyle(state.isActive ? WidgetPalette.cream : .secondary)
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
                        .foregroundStyle(state.isActive ? WidgetPalette.cream : .primary)
                }
                Text(state.isActive ? "Keeping the Mac awake" : "The Mac can sleep")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                        .stroke(.secondary, style: .init(
                            lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                }
                Path(BrandCupMark.saucer()).applying(transform)
                    .stroke(active ? WidgetPalette.brew : Color.secondary, style: .init(
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
            currentSharedState()?.isActive ?? false
        }
    }
}

/// The Control Center toggle's intent: same bridge as the widget buttons, but
/// it also opens the app so a stopped one launches and consumes the command.
@available(macOS 26.0, *)
struct SetKeepAwakeControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Keep Awake"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        send(value ? .start : .stop)
        return .result()
    }
}
