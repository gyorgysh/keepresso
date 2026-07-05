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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    jitterCard
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
        .onAppear { model.refreshStreaming() }
        .onReceive(awdlTick) { _ in model.refreshAWDLState() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gaming & Streaming")
                    .font(.title2.bold())
                Text("macOS hops the Wi-Fi radio off-channel for AWDL about once a second, "
                     + "which shows up as ping spikes mid-game or mid-stream. Diagnose it here, "
                     + "and pause AWDL for the session if it's the culprit.")
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
        case .clean: "Latency looks clean."
        case .looksLikeAWDL: "Once-a-second spikes: this looks like AWDL."
        case .jittery: "Spiky, but not on AWDL's cadence (congestion or a weak signal)."
        case .inconclusive: "Not enough replies to judge."
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

    private var watchdogCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("AWDL watchdog", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text(interfaceStateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Pause AWDL now", isOn: Binding(
                get: { model.awdl.isRunning },
                set: { model.setAWDLWatchdog($0) }
            ))
            .toggleStyle(.switch)
            .disabled(model.awdl.isBusy)

            if model.awdl.isBusy {
                Text("Waiting for your password…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.awdl.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Turns the pause on right now and keeps it on until you turn it off or quit Keepresso (it isn't tied to whether a keep-awake session is brewing). While it's on, AirDrop, Handoff, Sidecar, and Continuity Camera take a break, and the once-a-second lag spikes stop. Everything comes back the moment you turn it off or quit Keepresso; even if the app crashes, macOS is restored automatically. Your password is needed only the first time after each launch; after that the switch is instant.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Pause AWDL automatically while gaming", isOn: Binding(
                get: { model.awdlAutoWithGaming },
                set: { model.awdlAutoWithGaming = $0 }
            ))
            .toggleStyle(.switch)
            Text("Watches for a game (or a cloud-gaming app like GeForce NOW) coming to the front and pauses AWDL on its own, then lifts the pause about a minute after you stop. No trigger setup needed: leave this on and forget it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var interfaceStateLabel: String {
        switch model.awdl.isInterfaceUp {
        case true: "AWDL is on right now"
        case false: "AWDL is off right now"
        case nil: "AWDL state unknown"
        }
    }
}
