import SwiftUI
import WebKit
import KeepressoCore

/// The quit modal: an animated "did you forget to turn it off" illustration
/// plus variant copy, run app-modal while termination waits. The SVG asset
/// carries no text, so translators never see it; every string below goes
/// through the localization catalog.
struct QuitSleepModalView: View {
    enum Action {
        case turnOffAndQuit
        case quitAnyway
        case stopBrewingAndQuit
        case cancel
    }

    let coverage: QuitSleepCheck.Coverage
    let device: String
    let qualifier: String?
    let decide: (Action) -> Void

    var body: some View {
        VStack(spacing: 12) {
            SleepArtWebView()
                .frame(width: 200, height: 140)
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                if showsSessionLine {
                    Text(verbatim: L("A keep-awake session is still brewing. Quitting stops it now instead of at its timer."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if showsOverrideLine {
                    Text(verbatim: overrideLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                if showsOverrideActions {
                    Button("Cancel") { decide(.cancel) }
                        .buttonStyle(.link)
                        .keyboardShortcut(.cancelAction)
                    Button("Quit anyway") { decide(.quitAnyway) }
                        .buttonStyle(.link)
                    Button("Turn off and quit") { decide(.turnOffAndQuit) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { decide(.cancel) }
                        .keyboardShortcut(.cancelAction)
                    Button("Stop brewing and quit") { decide(.stopBrewingAndQuit) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var title: LocalizedStringKey {
        switch coverage {
        case .session: "Quit while still brewing?"
        default: "Did you forget to turn it off?"
        }
    }

    private var showsSessionLine: Bool {
        coverage == .session || coverage == .sessionAndOverride
    }

    private var showsOverrideLine: Bool {
        coverage == .overrideLive || coverage == .sessionAndOverride
    }

    private var showsOverrideActions: Bool { showsOverrideLine }

    private var overrideLine: String {
        if let qualifier {
            L("%@ would stay awake with the lid shut and nothing managing it, %@.", device, qualifier)
        } else {
            L("%@ would stay awake with the lid shut and nothing managing it.", device)
        }
    }
}

/// The bundled animated illustration, rendered in a chromeless web view.
/// Transparent page background so the panel shows through; the file access
/// is scoped to its own folder.
struct SleepArtWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.underPageBackgroundColor = .clear
        if let url = Bundle.main.url(
            forResource: "quit-sleep", withExtension: "svg", subdirectory: "QuitArt"
        ) {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Synchronous app-modal wrapper: takes over the main thread with a nested
/// runloop until a button answers. Callers must have a termination reply (or
/// equivalent) waiting on the outcome.
final class QuitSleepModal: NSObject {
    enum Decision {
        case turnOffAndQuit
        case quitAnyway
        case stopBrewingAndQuit
        case cancel
    }

    private enum Code: Int {
        case turnOffAndQuit = 100
        case quitAnyway = 101
        case stopBrewingAndQuit = 102
    }

    func ask(
        coverage: QuitSleepCheck.Coverage,
        device: String,
        qualifier: String?
    ) -> Decision {
        var answer = Decision.cancel
        let view = QuitSleepModalView(
            coverage: coverage, device: device, qualifier: qualifier
        ) { action in
            switch action {
            case .turnOffAndQuit:
                answer = .turnOffAndQuit
                NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Code.turnOffAndQuit.rawValue))
            case .quitAnyway:
                answer = .quitAnyway
                NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Code.quitAnyway.rawValue))
            case .stopBrewingAndQuit:
                answer = .stopBrewingAndQuit
                NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Code.stopBrewingAndQuit.rawValue))
            case .cancel:
                answer = .cancel
                NSApp.stopModal(withCode: .cancel)
            }
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        panel.contentView = NSHostingView(rootView: view)
        if let fitting = panel.contentView?.fittingSize {
            panel.setContentSize(NSSize(width: 380, height: fitting.height))
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }
}
