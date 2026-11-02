import SwiftUI

/// The brand cup with rising steam, echoing the animated mark on the website:
/// three wisps that fade in low, drift up, and dissolve, on a staggered loop.
///
/// This lives in the menu dropdown and other real windows, where SwiftUI
/// animation runs normally. The menu bar *label* stays a static template image
/// of the same mark: a `MenuBarExtra` label is snapshotted, so nothing
/// animates there (see `MenuBarLabel`).
struct BrewingCupView: View {
    /// Whether a session is running: steam rises and the cup fills with the
    /// brew accent. Idle shows a quiet outline cup and reserves the steam space
    /// so the layout doesn't jump.
    var isActive: Bool

    /// Whether the battery pause is holding the session: the idle cup keeps a
    /// last sip of low-power yellow at the bottom, matching the menu bar icon.
    var pausedLowBattery: Bool = false

    /// Size multiplier over the menu-header size (22 pt wide). Everything
    /// scales together (paths, stroke widths, drift), so a window header can
    /// show the same mark large and still crisp.
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The animated pour level (0 empty, 1 full). Appears in the current
    /// state; only a live `isActive` change plays the pour or the drain.
    @State private var fill: CGFloat
    /// Steam waits for the pour to finish, so the sequence reads pour first,
    /// then steam, rather than everything at once.
    @State private var steaming: Bool

    /// Seeded from `isActive` rather than defaulted to empty. `onAppear` also
    /// sets both, but it runs a frame late, and anything that renders only
    /// one frame (a window snapshot, a modal opening) caught the empty
    /// outline cup instead of the brewing one.
    init(isActive: Bool, pausedLowBattery: Bool = false, scale: CGFloat = 1) {
        self.isActive = isActive
        self.pausedLowBattery = pausedLowBattery
        self.scale = scale
        _fill = State(initialValue: isActive ? 1 : 0)
        _steaming = State(initialValue: isActive)
    }
    /// Whether the host window is actually on screen. `MenuBarExtra(.window)`
    /// keeps this view alive after its panel closes on current macOS, so the
    /// steam `TimelineView` would otherwise keep firing (and a full window
    /// relayout) forever while the menu is shut. Reported by
    /// ``WindowVisibilityReader``; the steam only ticks while true.
    @State private var windowVisible = true

    /// One full rise-and-dissolve cycle per wisp, staggered thirds apart.
    static let loopDuration: TimeInterval = 3.4
    static let wispDelays: [TimeInterval] = [0, 1.15, 2.3]

    var body: some View {
        VStack(spacing: 1 * scale) {
            steam
                .frame(width: 22 * scale, height: 9 * scale)
                .animation(.easeInOut(duration: 0.25), value: steaming)
            BrandCupGlyph(fill: fill, lowSip: pausedLowBattery && !isActive)
                .frame(width: 22 * scale, height: 16.6 * scale)
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .accessibilityHidden(true) // the header text next to it carries the status
        .onAppear {
            fill = isActive ? 1 : 0
            steaming = isActive
        }
        .onChange(of: isActive) { _, active in
            guard !reduceMotion else {
                fill = active ? 1 : 0
                steaming = active
                return
            }
            steaming = false
            if active {
                withAnimation(.easeOut(duration: 0.55)) {
                    fill = 1
                } completion: {
                    // Only steam if nothing drained the cup mid-pour.
                    if fill == 1 { steaming = true }
                }
            } else {
                withAnimation(.easeIn(duration: 0.4)) { fill = 0 }
            }
        }
    }

    @ViewBuilder
    private var steam: some View {
        if steaming && windowVisible && !reduceMotion {
            // Core Animation, not a timeline: the wisps move in the render
            // server, so the app does no work per frame. A 30 Hz timeline
            // here made SwiftUI redraw the whole menu panel, text included,
            // thirty times a second. Unmounts with this branch.
            CupSteamLayer(scale: scale)
        } else if steaming {
            // Reduce Motion, or the host window is off screen (a closed
            // `MenuBarExtra` panel keeps its content alive on current macOS):
            // steady mid-rise steam, with no display-link ticking behind it.
            wisps { _ in (opacity: 0.55, rise: -1) }
        } else {
            Color.clear
        }
    }

    private func wisps(state: (TimeInterval) -> (opacity: Double, rise: CGFloat)) -> some View {
        let states = Self.wispDelays.map(state)
        return HStack(alignment: .bottom, spacing: 3.5 * scale) {
            ForEach(0 ..< 3) { index in
                let wisp = states[index]
                SteamWisp()
                    .stroke(Color.keepressoSteam, style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round))
                    .frame(width: 4 * scale, height: (index == 1 ? 8 : 6.5) * scale)
                    .opacity(wisp.opacity)
                    .offset(y: wisp.rise * scale)
            }
        }
    }
}

/// The three wisps as shape layers, each on the website mark's keyframed loop
/// (fade in while rising from below, thin out past the midpoint, gone by the
/// top), staggered by its delay.
private struct CupSteamLayer: NSViewRepresentable {
    var scale: CGFloat

    func makeNSView(context: Context) -> CupSteamView { CupSteamView() }

    func updateNSView(_ view: CupSteamView, context: Context) {
        view.scale = scale
    }
}

private final class CupSteamView: NSView {
    private let wisps = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Top-left origin, so offsets read like the SwiftUI layout's.
        layer?.isGeometryFlipped = true
        for wisp in wisps {
            wisp.fillColor = nil
            wisp.lineCap = .round
            wisp.opacity = 0
            layer?.addSublayer(wisp)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { animate() }
    }

    override func layout() {
        super.layout()
        // The SwiftUI layout: three wisps 4 pt wide, 3.5 pt apart, bottom
        // aligned and centered in the 22 x 9 pt steam area; the middle one
        // taller.
        let width = 4 * scale
        let spacing = 3.5 * scale
        let total = width * 3 + spacing * 2
        let left = (bounds.width - total) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, wisp) in wisps.enumerated() {
            let height = (index == 1 ? 8 : 6.5) * scale
            let frame = CGRect(
                x: left + CGFloat(index) * (width + spacing),
                y: bounds.height - height, width: width, height: height)
            wisp.frame = frame
            wisp.lineWidth = 1.5 * scale
            wisp.path = SteamWisp().path(in: CGRect(origin: .zero, size: frame.size)).cgPath
        }
        CATransaction.commit()
        applyColor()
        animate()
    }

    private func applyColor() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(Color.keepressoSteam).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wisps.forEach { $0.strokeColor = color }
        CATransaction.commit()
    }

    private func animate() {
        guard window != nil, bounds.width > 0 else { return }
        let phases: [NSNumber] = [0, 0.30, 0.65, 1]
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        for (index, wisp) in wisps.enumerated() {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.85, 0.30, 0]
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = [2.5, 0, -2.5, -4].map { $0 * scale }
            let group = CAAnimationGroup()
            for keyframes in [opacity, rise] {
                keyframes.keyTimes = phases
                keyframes.timingFunctions = [ease, ease, ease]
            }
            group.animations = [opacity, rise]
            group.duration = BrewingCupView.loopDuration
            group.repeatCount = .infinity
            // Anchored to media time zero, shifted by the wisp's delay so each
            // runs that far ahead of the first. A fixed anchor means
            // re-animating (a relayout, a reopened panel) continues the loop
            // rather than restarting it.
            group.beginTime = wisp.convertTime(0, from: nil) - BrewingCupView.wispDelays[index]
            group.fillMode = .both
            wisp.removeAllAnimations()
            wisp.add(group, forKey: "steam")
        }
    }
}

/// A single S-curved steam wisp, the same stroke the website mark uses.
private struct SteamWisp: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX - rect.width * 0.4, y: rect.maxY - rect.height * 0.35),
            control2: CGPoint(x: rect.maxX + rect.width * 0.4, y: rect.minY + rect.height * 0.35)
        )
        return path
    }
}
