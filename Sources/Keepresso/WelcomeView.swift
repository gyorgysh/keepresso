import SwiftUI
import AppKit
import UserNotifications
import KeepressoCore

/// The first-run welcome window: a short intro to a menu-bar app that has no
/// Dock icon or main window, then a one-click "how do you use your Mac" setup
/// that applies a matching trigger preset, plus a couple of general options.
/// Shown once on the first launch (gated by ``AppModel/hasOnboarded``) and
/// reopenable from Preferences > General. Every step here acts only when its
/// control is used; nothing prompts for a permission just because the window
/// opened.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.isEnabled
    /// The live notification authorization status, so the row reflects "already
    /// on" / "not asked" / "denied" instead of always offering Enable.
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// The preset id of the use case the user picked, for the checkmark. Local
    /// to this window: applying a preset is the persisted action.
    @State private var selectedUseCase: String?

    /// A way someone uses their Mac, mapped to a built-in preset that sets up the
    /// matching triggers in one tap.
    private struct UseCase: Identifiable {
        let id: String // the built-in preset id to apply
        let title: String
        let detail: String
        let icon: String
    }

    /// The id of the opt-out row: no triggers, keep-awake stays a manual toggle.
    private static let manualID = "manual"

    private static let useCases: [UseCase] = [
        UseCase(id: "ai-agent", title: "Agentic coding",
                detail: "Stay awake while Claude, Codex, or Grok is running.", icon: "terminal"),
        UseCase(id: "cloud-gaming", title: "Gaming & streaming",
                detail: "Stay awake while a game or cloud-gaming app is in front.", icon: "gamecontroller"),
        UseCase(id: "meetings", title: "Meetings & calls",
                detail: "Stay awake whenever the camera or microphone is in use.", icon: "video"),
        UseCase(id: "remote-session", title: "Remote access",
                detail: "Stay awake while someone is connected over SSH.", icon: "network"),
        UseCase(id: manualID, title: "Keep it manual for now",
                detail: "Just toggle keep-awake yourself, and set up your own triggers later in Preferences.",
                icon: "hand.tap"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                Text("Welcome to Keepresso")
                    .font(.title2.bold())
                Text("Keepresso keeps your Mac awake on your terms. It lives in the menu bar near the clock, with no Dock icon. Click its cup any time to start or stop.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("How do you use your Mac?")
                    .font(.callout.weight(.semibold))
                Text("Pick one to set up matching triggers, or keep it manual and add your own later. You can change this any time in Preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.useCases) { useCase in
                    useCaseRow(useCase)
                }
                if selectedUseCase == "cloud-gaming" {
                    gamingJitterCallout
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                setupRow(
                    icon: "power",
                    title: "Launch at login",
                    detail: "Start Keepresso automatically when you log in."
                ) {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { LoginItem.setEnabled($0); launchAtLogin = LoginItem.isEnabled }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                setupRow(
                    icon: "bell.badge",
                    title: "Notifications",
                    detail: "Let Keepresso remind you when a long session is still keeping the Mac awake."
                ) {
                    notificationControl
                }
            }

            Divider()

            HStack {
                Link("Learn more", destination: AppInfo.repository)
                    .font(.callout)
                Spacer()
                Button("Get Started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .tint(.keepressoBrew)
        .glassWindowBackground()
        // The one-shot is consumed by actually being seen, not by the attempt
        // to open the window (see `MenuBarLabelView`): if launch is cut short
        // (DMG relocation hand-off) the flag stays false for the real run.
        .onAppear { model.hasOnboarded = true }
        .task { notificationStatus = await model.notificationAuthorizationStatus() }
    }

    /// The Notifications row's trailing control, reflecting the real permission
    /// state: already granted shows a static "Enabled", a prior denial sends the
    /// user to System Settings (a re-request would silently no-op), and only an
    /// undecided state offers to ask.
    @ViewBuilder
    private var notificationControl: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .denied:
            Button("Open Settings") { openNotificationSettings() }
        default: // .notDetermined and any future case: safe to ask
            Button("Enable") {
                Task { notificationStatus = await model.requestNotificationAuthorization() }
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Offered when the gaming use case is picked: a hop to the Gaming &
    /// Streaming window, where AWDL pausing (which steadies the connection and
    /// cuts jitter) and the jitter test live. A hand-off rather than an inline
    /// enable, because turning AWDL on needs an administrator password, which
    /// that window sets up in context (and its jitter test shows whether it's
    /// even needed first). Opening a window never prompts.
    private var gamingJitterCallout: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(.title3)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reduce lag and jitter")
                    .font(.callout.weight(.medium))
                Text("Pause AWDL to steady your connection, and test your jitter, in Gaming & Streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Set Up\u{2026}") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: KeepressoApp.streamingWindowID)
            }
        }
        .padding(8)
        .background(Color.keepressoBrew.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Act on a picked use case: the manual opt-out turns trigger gating off (so
    /// keep-awake stays a plain manual toggle), any other applies its preset,
    /// which switches the rule set and turns triggers on.
    private func apply(_ useCase: UseCase) {
        if useCase.id == Self.manualID {
            model.triggersEnabled = false
        } else if let preset = Preset.builtIns.first(where: { $0.id == useCase.id }) {
            model.applyPreset(preset)
        }
        selectedUseCase = useCase.id
    }

    /// A pickable use case: applying it switches the whole rule set to the
    /// matching preset (a switch, not a merge) and turns triggers on.
    private func useCaseRow(_ useCase: UseCase) -> some View {
        let selected = selectedUseCase == useCase.id
        return Button {
            apply(useCase)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: useCase.icon)
                    .font(.title3)
                    .foregroundStyle(Color.keepressoBrew)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(useCase.title).font(.callout.weight(.medium))
                    Text(useCase.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.keepressoBrew : Color.secondary)
            }
            .padding(8)
            .background(selected ? Color.keepressoBrew.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One general setup step: an SF Symbol, a title and explanation, and a
    /// trailing control (a toggle or a button).
    @ViewBuilder
    private func setupRow<Control: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.keepressoBrew)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}
