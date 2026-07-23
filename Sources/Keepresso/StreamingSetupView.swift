import SwiftUI
import AppKit
import KeepressoCore

/// The Gaming & Streaming Setup screen (v1.6): answers "why does my stream or
/// cloud game stutter every second". A built-in jitter test reproduces the
/// AWDL diagnosis from the blog post, a session-scoped watchdog is the fix,
/// and readiness rows cover the radio hygiene around it (wired network, Wi-Fi
/// channel alignment, Bluetooth).
struct StreamingSetupView: View {
    @Bindable var model: AppModel

    /// Keeps the AWDL on/off readout honest while the window is open: the
    /// helper flips the interface up to a few seconds after a toggle.
    private let awdlTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// A lighter 1s pulse (no shell-out) so the auto-gaming grace countdown
    /// ticks down smoothly.
    private let statusTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var statusPulse = 0
    /// Whether the window is actually on screen. The closed window keeps this
    /// view alive on current macOS, so both ticks gate on this.
    @State private var windowVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    jitterCard
                    gameComfortCard
                    watchdogCard
                    ForEach(model.streaming.checks) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 560)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        .centersAndFrontsWindow()
        .onAppear { model.refreshStreaming() }
        // The closed window keeps this content alive (see WindowVisibilityReader),
        // so the AWDL poll would keep spawning ifconfig unseen. Pause both ticks
        // while hidden and refresh on reopen.
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, visible in
            if visible { model.refreshStreaming() }
        }
        .onReceive(awdlTick) { _ in
            guard windowVisible else { return }
            model.refreshAWDLState()
        }
        .onReceive(statusTick) { _ in
            guard windowVisible else { return }
            statusPulse &+= 1
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gaming & Streaming")
                    .font(.title2.bold())
                Text("macOS hops the Wi-Fi radio off-channel for AWDL about once a second, which shows up as ping spikes mid-game or mid-stream. Diagnose it here, and pause AWDL for the session if it's the culprit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.refreshStreaming()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }

    // MARK: - Jitter test

    private var jitterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Jitter test", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Button("Run Test") {
                    Task { await model.jitter.run() }
                }
                .disabled(model.jitter.state == .running)
            }
            Text("Pings 1.1.1.1 five times a second for 10 seconds and checks whether latency spikes on AWDL's once-a-second cadence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.jitter.state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Measuring, about 10 seconds…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            case .failed:
                Text("The test couldn't run. Check that you're online and try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            case .finished(let report):
                jitterResult(report)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func jitterResult(_ report: JitterReport) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: verdictGlyph(report.verdict))
                .foregroundStyle(verdictTint(report.verdict))
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictHeadline(report.verdict))
                    .font(.callout.weight(.semibold))
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.verdict == .looksLikeAWDL {
                    Text("The watchdog below should smooth this out; re-run the test with it on to confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
    }

    private func verdictHeadline(_ verdict: JitterVerdict) -> String {
        switch verdict {
        case .clean: L("Latency looks clean.")
        case .looksLikeAWDL: L("Once-a-second spikes: this looks like AWDL.")
        case .jittery: L("Spiky, but not on AWDL's cadence (congestion or a weak signal).")
        case .inconclusive: L("Not enough replies to judge.")
        }
    }

    private func verdictGlyph(_ verdict: JitterVerdict) -> String {
        switch verdict {
        case .clean: "checkmark.circle.fill"
        case .looksLikeAWDL: "exclamationmark.triangle.fill"
        case .jittery: "exclamationmark.circle.fill"
        case .inconclusive: "questionmark.circle.fill"
        }
    }

    private func verdictTint(_ verdict: JitterVerdict) -> Color {
        switch verdict {
        case .clean: .green
        case .looksLikeAWDL: .orange
        case .jittery: .orange
        case .inconclusive: .secondary
        }
    }

    // MARK: - AWDL watchdog

    /// Frame-comfort features while a game (or a streaming client like
    /// Parsec) is the active window.
    private var gameComfortCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("While you play", systemImage: "gamecontroller")
                .font(.headline)

            if model.wakeHelperGate == .ready {
                switchRow("Give the game high CPU priority", isOn: Binding(
                    get: { model.gamePriorityBoost },
                    set: { model.gamePriorityBoost = $0 }
                ))
                Text("Raises the active game or streaming app's CPU priority through the administrator helper, so background work (builds, backups, agent sessions) cannot steal frames. Normal priority comes back after you stop playing, and always when the game quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.gamePriority.boostedPID != nil {
                    Label(L("Boosting the current game."), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                // No dead toggle: the control is replaced by a lock row that
                // says why and offers the unlocking action.
                HStack {
                    Text("Give the game high CPU priority")
                    Spacer()
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Locked until the helper is ready"))
                }
                HelperLockedRow(model: model, context: .gamePriority)
                    .font(.caption)
            }

            switchRow("Keep the display awake with a controller", isOn: Binding(
                get: { model.controllerPokeWhileGaming },
                set: { model.controllerPokeWhileGaming = $0 }
            ))
            Text("Controller input does not always count as user activity, so a gamepad-only session can dim or sleep the display mid-game. While a game is in front, a controller is connected, and a keep-awake session is active, Keepresso reports activity for you every half minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var watchdogCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label("AWDL watchdog", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    // The radiating waves animate only while the watchdog is
                    // actively pausing AND the window is on screen: the
                    // closed window keeps this view alive (see
                    // WindowVisibilityReader), so an unconditional effect
                    // would render unseen frames forever.
                    .symbolEffect(
                        .variableColor.iterative,
                        isActive: model.awdlStatus.isPausing && windowVisible
                    )
                InfoButton(text: L("macOS scans for AirDrop, Handoff, and Sidecar peers on the same Wi-Fi radio about once a second, and each hop can spike your ping. That reads as stutter in cloud gaming, remote play, and live streams. The watchdog turns those hops off (pausing the AWDL interface) while you play and brings everything back afterward, automatically with the game detection below or manually with the switch."))
                Spacer()
                Text(interfaceStateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("The stutter fix for streaming and online gaming.")
                .font(.caption)
                .foregroundStyle(.secondary)

            awdlStatusRow

            switchRow("Pause AWDL now", isOn: Binding(
                get: { model.awdl.isRunning },
                set: { model.setAWDLWatchdog($0) }
            ))
            .disabled(model.awdl.isBusy)

            if model.awdl.isBusy && !model.helperInstalled {
                AdminAuthNote(purpose: L("pause AWDL (turn off the Wi-Fi AirDrop/Handoff radio hops)"))
            }
            if let error = model.awdl.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Turns the pause on right now and keeps it on until you turn it off or quit Keepresso (it isn't tied to whether a keep-awake session is brewing). While it's on, AirDrop, Handoff, Sidecar, and Continuity Camera take a break, and the once-a-second lag spikes stop. Everything comes back the moment you turn it off or quit Keepresso; even if the app crashes, macOS is restored automatically. With the administrator helper installed the switch is always instant and silent; without it, macOS asks for your password once per launch (the system dialog may show “osascript”, which is Keepresso running the command).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            switchRow("Pause AWDL automatically while gaming", isOn: Binding(
                get: { model.awdlAutoWithGaming },
                set: { model.awdlAutoWithGaming = $0 }
            ))
            Text("Watches for a game (or a cloud-gaming app like GeForce NOW) as the active window and pauses AWDL on its own, then lifts the pause a little after you switch away (the delay below). It only counts while the game is in front and in use, not just running in the background. Without the administrator helper, turning this on asks for your password once per app run, right now rather than mid-game; with the helper it never asks at all. No trigger setup needed: leave this on and forget it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Resume AWDL after leaving the game", selection: Binding(
                get: { model.awdlGraceSeconds },
                set: { model.awdlGraceSeconds = $0 }
            )) {
                Text("10 seconds").tag(TimeInterval(10))
                Text("30 seconds").tag(TimeInterval(30))
                Text("1 minute").tag(TimeInterval(60))
                Text("2 minutes").tag(TimeInterval(120))
                Text("5 minutes").tag(TimeInterval(300))
            }
            .pickerStyle(.menu)
            .disabled(!model.awdlAutoWithGaming)
            Text("How long the pause lingers after the game stops being the active window, so a quick alt-tab doesn't flap the radios. Shorter brings AirDrop and Handoff back faster; longer rides out launchers and loading screens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switchRow("Notify when auto-pausing and resuming", isOn: Binding(
                get: { model.awdlNotifications },
                set: { model.awdlNotifications = $0 }
            ))
            Text("Posts a notification when a game is detected and AWDL pauses, and again when it resumes. A notice that your administrator password is needed is always sent (even behind a fullscreen game), regardless of this switch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HelperStatusRows(model: model)
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// A status pill showing why AWDL is paused (or its grace countdown after a
    /// game closes). Hidden when the watchdog isn't running.
    @ViewBuilder
    private var awdlStatusRow: some View {
        let _ = statusPulse // re-read the live status (and grace countdown) each second
        if let style = AWDLStatusStyle(model.awdlStatus) {
            HStack(spacing: 6) {
                Image(systemName: style.icon)
                    .foregroundStyle(style.color)
                    .accessibilityHidden(true)
                Text(style.text)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(style.color.opacity(0.12), in: Capsule())
        }
    }

    private var interfaceStateLabel: String {
        switch model.awdl.isInterfaceUp {
        case true: L("AWDL is on right now")
        case false: L("AWDL is off right now")
        case nil: L("AWDL state unknown")
        }
    }
}
