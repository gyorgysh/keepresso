import SwiftUI
import KeepressoCore

/// The quit modal: brand art with looping native animation, variant copy, and
/// a warning badge, run app-modal while termination waits. It deliberately
/// mirrors ``HelperAttentionView`` (centered copy, copper badge and
/// bronze-tinted buttons) so a quit-time warning reads as the same app.
/// Every string reuses an existing catalog key, so no language falls back.
///
/// The art is drawn, not loaded: ``SessionArt`` pours nothing and waits for
/// no appear event (a static filled glyph plus timeline steam), and
/// ``LidClosedArt`` warns about the lid-shut override with a breathing sleep
/// LED and rising Zzz. Both honor Reduce Motion with a steady frame.
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
    /// Lid mode is on but the session automation holds it, so quitting ends
    /// it by itself. Shown, not warned about.
    var scopedLid: Bool = false
    let decide: (Action) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if showsLidArt {
                    LidClosedArt()
                } else {
                    SessionArt()
                }
            }
            .frame(width: 200, height: 140)

            VStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.title3.bold())
                if showsSessionLine {
                    Text(verbatim: L("A keep-awake session is still brewing. Quitting stops it now instead of at its timer."))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsOverrideLine {
                    Text(verbatim: overrideLine)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if scopedLid {
                    Text(verbatim: L("Closed-display mode is on for this session. Quitting ends it, so the lid can sleep %@ again.", device))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsLidArt {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(Color.keepressoBrew)
                    // Names the feature in Preferences' own words and warns
                    // it stays on until switched off: that is the indefinite
                    // part the dialog exists to prevent stranding.
                    Text(verbatim: showsOverrideLine
                        ? L("Keep running with the lid shut and no external display. Stays on until you switch it off.")
                        : L("Keep running with the lid shut and no external display."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 8, tint: Color.keepressoBrew.opacity(0.14))
            }

            HStack {
                Button("Cancel") { decide(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if showsOverrideActions {
                    Button("Quit anyway") { decide(.quitAnyway) }
                    Button("Turn off and quit") { decide(.turnOffAndQuit) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop brewing and quit") { decide(.stopBrewingAndQuit) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        // The bronze buttons: without this the default action renders
        // system blue, which belongs to no part of this app.
        .tint(.keepressoBrew)
    }

    /// Through `L` (not a bare literal) so the localization gate sees the
    /// keys: a renamed literal must never silently fall back to English.
    private var title: String {
        switch coverage {
        case .session: L("Quit while still brewing?")
        default: L("Did you forget to turn it off?")
        }
    }

    /// Only when the session is the whole story. With the lid line present,
    /// the session sentence is the one nobody reads: the stranded override is
    /// the consequence worth acting on, and two paragraphs bury it.
    private var showsSessionLine: Bool {
        coverage == .session
    }

    private var showsOverrideLine: Bool {
        coverage == .overrideLive || coverage == .sessionAndOverride
    }

    private var showsOverrideActions: Bool { showsOverrideLine }

    /// The lid figure stands in whenever lid mode is actually on, however it
    /// is held. Which held it only changes the words and the buttons.
    private var showsLidArt: Bool { showsOverrideLine || scopedLid }

    private var overrideLine: String {
        if let qualifier {
            L("%@ would stay awake with the lid shut and nothing managing it, %@.", device, qualifier)
        } else {
            L("%@ would stay awake with the lid shut and nothing managing it.", device)
        }
    }
}

/// The brand mark itself, brewing, at modal size. Deliberately
/// ``BrewingCupView`` rather than a local redraw: the cup, the steam
/// geometry, the wisp count and spacing, the loop timing and the Reduce
/// Motion frame all have one definition, so the modal cannot drift away from
/// the menu bar and the dropdown.
private struct SessionArt: View {
    var body: some View {
        BrewingCupView(isActive: true, scale: 4.6)
            .accessibilityHidden(true)
    }
}

/// The website's LidClose figure, ported to SwiftUI: a MacBook whose lid
/// snaps shut with an overshoot bounce on a 6.5s loop while the green awake
/// LED and the copper activity bars never stop, over the site's steam
/// timing. Geometry and keyframes mirror home.jsx (viewBox 380x260),
/// colors resolve to the app palette. Draws the full closed-lid frame even
/// when the timeline never ticks; steady closed frame under Reduce Motion.
private struct LidClosedArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                LidCloseFigure(time: 0, reduceMotion: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    LidCloseFigure(time: context.date.timeIntervalSinceReferenceDate, reduceMotion: false)
                }
            }
        }
        .frame(width: 200, height: 140)
        .accessibilityHidden(true)
    }
}

/// Drawn at its final 200x140 size, no `scaleEffect`: the previous version
/// laid out a 380x260 canvas and scaled it down, which neither clips nor
/// resizes the layout frame, so the figure overflowed its slot and sat in a
/// thin band with most of the canvas empty.
private struct LidCloseFigure: View {
    var time: TimeInterval
    var reduceMotion: Bool

    /// Where the lid meets the base. The hinge is the lid rect's own
    /// bottom-trailing corner, which is what makes the rotation anchor work.
    private static let deskY: CGFloat = 125
    private static let baseCenter = CGPoint(x: 126, y: 122)
    private static let baseSize = CGSize(width: 112, height: 6)
    private static let lidSize = CGSize(width: 110, height: 5)

    var body: some View {
        ZStack {
            // Desk line.
            Path { path in
                path.move(to: CGPoint(x: 16, y: Self.deskY))
                path.addLine(to: CGPoint(x: 184, y: Self.deskY))
            }
            .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // The base, sitting on the desk.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.22))
                .stroke(Color.secondary, lineWidth: 1.2)
                .frame(width: Self.baseSize.width, height: Self.baseSize.height)
                .position(Self.baseCenter)

            // The awake LED: the Mac stays up under the shut lid.
            Circle()
                .fill(Color.green)
                .frame(width: 3.6, height: 3.6)
                .position(x: 80, y: Self.baseCenter.y)
                .opacity(reduceMotion ? 1 : ledOpacity(at: time))

            // The lid. Rotation goes *before* `position`: positioning first
            // expands the view to fill the parent, so `.bottomTrailing` would
            // be the canvas corner rather than the hinge, which is what flung
            // the lid off to the window edge as a vertical bar. Anchored to
            // the lid's own corner, a positive angle turns the free end
            // clockwise from west to north, standing the lid up.
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary)
                .frame(width: Self.lidSize.width, height: Self.lidSize.height)
                .rotationEffect(
                    .degrees(reduceMotion ? 0 : Self.lidAngle(at: time)),
                    anchor: .bottomTrailing)
                .position(
                    x: Self.baseCenter.x - 1,
                    y: Self.baseCenter.y - (Self.baseSize.height + Self.lidSize.height) / 2)

            // The brand mark beside the Mac, standing on the same desk line.
            BrewingCupView(isActive: true, scale: 1.5)
                .position(x: 40, y: Self.deskY - 26.6 * 1.5 / 2)
        }
        .frame(width: 200, height: 140)
    }

    /// Hold open, snap shut with an overshoot bounce, hold closed, glide back
    /// open. Whole loop 6.5s. 90 is fully open, 0 fully shut; the caller
    /// negates it to turn the lid the right way.
    static func lidAngle(at time: TimeInterval) -> Double {
        let phase = (time.truncatingRemainder(dividingBy: 6.5)) / 6.5
        switch phase {
        case ..<0.15: return 90
        case ..<0.27: return 90 - 90 * cubicBezier((phase - 0.15) / 0.12, 0.55, 0, 0.9, 0.6)
        case ..<0.31: return 6 * easeOut((phase - 0.27) / 0.04)
        case ..<0.35: return 6 - 6 * easeIn((phase - 0.31) / 0.04)
        case ..<0.63: return 0
        default: return 90 * cubicBezier((phase - 0.63) / 0.37, 0.4, 0, 0.35, 1)
        }
    }

    private static func easeIn(_ t: Double) -> Double { t * t * t }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    /// Standard cubic-bezier easing solve (Newton-Raphson on x, then y).
    private static func cubicBezier(_ t: Double, _ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) -> Double {
        var x = t
        for _ in 0..<8 {
            let x2 = bezier(x, c1x, c2x) - t
            let slope = bezierSlope(x, c1x, c2x)
            guard abs(slope) > 1e-6 else { break }
            x -= x2 / slope
            x = min(1, max(0, x))
        }
        return bezier(x, c1y, c2y)
    }

    private static func bezier(_ t: Double, _ c1: Double, _ c2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t
    }

    private static func bezierSlope(_ t: Double, _ c1: Double, _ c2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * c1 + 6 * u * t * (c2 - c1) + 3 * t * t * (1 - c2)
    }
}

/// The green awake LED, breathing on a 2.2s loop.
private func ledOpacity(at time: TimeInterval) -> Double {
    1 - 0.65 * (0.5 - 0.5 * cos(time * 2 * .pi / 2.2))
}

/// Presents the quit question in an ordinary window and calls back with the
/// answer. Deliberately **not** `NSApp.runModal`.
///
/// A nested modal session does not get the event stream here: quitting starts
/// from the menu bar extra, so `applicationShouldTerminate` runs inside menu
/// tracking, and the modal window comes up looking perfectly normal (key,
/// colored traffic lights) while every click, the red close button included,
/// goes to the tracking session instead. Running it from a `.terminateLater`
/// reply has the same shape of problem.
///
/// A plain window under `.terminateLater` is the pattern AppKit actually
/// supports, and it is what a document save sheet at quit uses: the run loop
/// keeps dispatching events normally, and the reply goes out when a button
/// answers. The caller must hold this object until the callback fires.
@MainActor
final class QuitSleepModal: NSObject, NSWindowDelegate {
    enum Decision {
        case turnOffAndQuit
        case quitAnyway
        case stopBrewingAndQuit
        case cancel
    }

    private var window: NSWindow?
    private var completion: ((Decision) -> Void)?

    func present(
        coverage: QuitSleepCheck.Coverage,
        device: String,
        qualifier: String?,
        scopedLid: Bool,
        completion: @escaping (Decision) -> Void
    ) {
        self.completion = completion
        let view = QuitSleepModalView(
            coverage: coverage, device: device, qualifier: qualifier, scopedLid: scopedLid
        ) { [weak self] action in
            switch action {
            case .turnOffAndQuit: self?.finish(.turnOffAndQuit)
            case .quitAnyway: self?.finish(.quitAnyway)
            case .stopBrewingAndQuit: self?.finish(.stopBrewingAndQuit)
            case .cancel: self?.finish(.cancel)
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = ""
        window.isReleasedWhenClosed = false
        // Above the rest without being a panel: a faceless agent app has no
        // other window to sit in front of, and this must not get lost.
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        if let fitting = window.contentView?.fittingSize {
            window.setContentSize(NSSize(width: 380, height: fitting.height))
        }
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A second Cmd-Q while the question is up: re-focus it rather than
    /// opening another or quitting behind it.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The red close button means "don't quit". Answer, but leave the actual
    /// teardown to ``finish(_:)`` so the window cannot be pulled apart from
    /// two directions at once.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    /// Idempotent: a second press while the first is still unwinding (or a
    /// close on top of a button) must not reply to termination twice.
    private func finish(_ decision: Decision) {
        guard let completion else { return }
        self.completion = nil
        if let window {
            window.delegate = nil
            window.orderOut(nil)
            // Tear the SwiftUI host down while the window is still valid: the
            // art drives a `TimelineView`, whose display link would otherwise
            // stay armed and fire into freed memory on the next tick.
            window.contentView = nil
        }
        window = nil
        completion(decision)
    }
}
