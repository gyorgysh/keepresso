import SwiftUI

/// The "thinking" glyph next to an agent session in the menu, one per tool:
/// a working session spins the mark its own CLI spins, so a glance at the row
/// says which tool is busy before the label is read.
///
/// An idle session shows the same small dot whichever tool it belongs to. That
/// keeps a quiet list quiet and uniform, and leaves motion meaning exactly one
/// thing: this session is working right now.
///
/// Drawn rather than typed. The obvious spelling is a row of Unicode glyphs
/// (`·✢✳✶✻✽` for Claude, braille cells for the others), which is what this used
/// to be, but the system font contains none of them: every one falls back to
/// whatever face the system picks, which lands on shapes that look nothing
/// like the real thing. A `Shape` renders the same on every Mac, tints from
/// the row's foreground style, and stays crisp at any size.
///
/// Animated by Core Animation, not a SwiftUI timeline. Each frame is drawn
/// once into a mask image (cached per tool), and a discrete keyframe
/// animation steps a tinted layer through them in the render server. A
/// timeline here made SwiftUI redraw the whole menu panel, every row of text
/// included, at the spinner's rate. The call site still passes
/// `animated: false` while the panel is off screen, and the panel body
/// unmounts while closed, which drops the layer entirely.
struct SparkView: View {
    /// The agent this row belongs to, or `nil`. Anything without a mark of its
    /// own falls back to the breathing dot.
    var agent: String?
    /// False renders the rest dot with no animation behind it.
    var animated = true
    /// The working mark's colour. A layer can't read SwiftUI's foreground
    /// style, so the row passes the colour it would have set.
    var tint: Color = .primary

    private var sprite: AgentSprite {
        switch agent {
        case "claude": return .claudeSunburst
        case "cursor", "cursor-agent": return .cursorDots
        case "grok": return .grokDots
        case "agy", "antigravity": return .antigravityDots
        // Codex's own mark, and the fallback for every other tool. Keepresso
        // detects far more agents than have a mark drawn here, and a breathing
        // dot suits an unknown one: it says "working" without borrowing some
        // other vendor's shape to say it.
        default: return .breathingDot
        }
    }

    var body: some View {
        let sprite = sprite
        Group {
            if animated {
                SpriteLayerView(sprite: sprite, tint: tint)
            } else {
                RestDot()
            }
        }
        // A fixed footprint keeps the row text from shivering as the marks
        // grow, shrink, and swap dots.
        .frame(width: 12, height: 12)
    }
}

/// What every idle row shows. Sized to the dot Claude's pulse rests on, so the
/// quiet state is the one the menu already had.
struct RestDot: View {
    static let diameter: CGFloat = 3.1

    var body: some View {
        Circle().frame(width: Self.diameter, height: Self.diameter)
    }
}

/// One tool's spinner: its frames and the rate it steps through them. Only the
/// working state differs between tools; ``RestDot`` covers all of them at rest.
enum AgentSprite {
    case claudeSunburst
    case cursorDots
    case grokDots
    case breathingDot
    case antigravityDots

    /// Measured off each tool's own console spinner.
    var frameInterval: TimeInterval {
        switch self {
        case .claudeSunburst: return 0.13
        case .cursorDots: return 0.25
        case .grokDots: return 0.13
        case .breathingDot: return 0.094
        case .antigravityDots: return 0.093
        }
    }

    /// Frames in one full cycle.
    var frameCount: Int {
        switch self {
        case .claudeSunburst: return SunburstPulse.frames.count
        case .cursorDots: return CursorDots.frames.count
        case .grokDots: return GrokDots.frames.count
        case .breathingDot: return BreathingDot.frames.count
        case .antigravityDots: return AntigravityDots.frames.count
        }
    }

    /// `tick` counts frames from the start of the cycle; any non-negative
    /// value works, it wraps.
    @ViewBuilder
    func frame(at tick: Int) -> some View {
        switch self {
        case .claudeSunburst:
            SunburstPulse.view(SunburstPulse.frames[tick % SunburstPulse.frames.count])
        case .cursorDots:
            DotMatrix(grid: CursorDots.grid, lit: CursorDots.frames[tick % CursorDots.frames.count])
        case .grokDots:
            DotMatrix(grid: GrokDots.grid, lit: GrokDots.frames[tick % GrokDots.frames.count])
        case .breathingDot:
            BreathingDot.view(BreathingDot.frames[tick % BreathingDot.frames.count])
        case .antigravityDots:
            DotMatrix(
                grid: AntigravityDots.grid,
                lit: AntigravityDots.frames[tick % AntigravityDots.frames.count])
        }
    }
}

/// The rest dot, breathing: Codex's own mark, and the one every tool without a
/// drawn mark of its own wears. Alone among the marks it never changes shape or
/// size, only how strongly it shows, so a working row is the very dot every
/// idle row already has, slowly fading down and back.
///
/// That is what makes it the right default. Keepresso detects a good many more
/// agents than are drawn here, and a plain dot says "working" without putting
/// some other vendor's shape next to a tool it has nothing to do with. New
/// tools land on it until someone measures their spinner.
///
/// Eleven steps make one breath of just over a second, measured off the `codex`
/// console spinner. The curve is symmetric and holds the top for two steps
/// while passing through the bottom in one, which is what keeps it reading as a
/// breath rather than a blink.
enum BreathingDot {
    static let frames: [Double] = [
        1.00, 1.00, 0.92, 0.66, 0.37, 0.16, 0.09, 0.16, 0.37, 0.66, 0.92,
    ]

    static func view(_ opacity: Double) -> some View {
        RestDot().opacity(opacity)
    }
}

// MARK: - Claude

/// Claude's sunburst, pulsing from a dot out to a full burst and back. The
/// cycle breathes out twice, once as the dense ray burst and once as the open
/// petal one, resting on a dot between, so the mark reads as alive rather than
/// merely blinking.
enum SunburstPulse {
    struct Frame {
        let spokes: Int
        let style: Sunburst.Style
        /// How far the burst reaches, as a fraction of full extent.
        let reach: CGFloat
    }

    static let frames = [
        Frame(spokes: 0, style: .ray, reach: 0.26),
        Frame(spokes: 10, style: .ray, reach: 0.72),
        Frame(spokes: 10, style: .ray, reach: 1.00),
        Frame(spokes: 10, style: .ray, reach: 1.00),
        Frame(spokes: 10, style: .ray, reach: 0.64),
        Frame(spokes: 0, style: .ray, reach: 0.22),
        Frame(spokes: 6, style: .petal, reach: 0.80),
        Frame(spokes: 6, style: .petal, reach: 1.00),
        Frame(spokes: 6, style: .petal, reach: 1.00),
        Frame(spokes: 6, style: .petal, reach: 0.62),
    ]

    static func view(_ frame: Frame) -> some View {
        Sunburst(spokes: frame.spokes, style: frame.style, reach: frame.reach)
    }
}

/// A sunburst at one point in its pulse: `spokes` arms reaching `reach` of the
/// way out. Zero spokes is the bare dot the pulse passes through.
///
/// Proportions are measured off the rendered mark, as fractions of the full
/// outer radius. The two arm shapes are genuinely different, not one scaled:
/// the dense burst is built from even-width arms that overlap into a solid
/// centre, while the open one is built from tapered petals that stand clear of
/// a small detached core.
struct Sunburst: Shape {
    enum Style {
        /// Even-width arms running out of the centre, rounded at the tip.
        /// Enough of them cross that the middle fills in on its own, which is
        /// where the mark's solid core comes from.
        case ray
        /// Petals that swell about three quarters of the way out and stop
        /// short of the middle, leaving the core standing on its own.
        case petal
    }

    var spokes: Int
    var style: Style
    var reach: CGFloat

    /// Even arms: width, held constant from the centre to the rounded tip.
    private static let rayWidth: CGFloat = 0.21
    /// Petals: where one starts, how wide it swells, and the core they ring.
    private static let petalInset: CGFloat = 0.32
    private static let petalWidth: CGFloat = 0.38
    private static let petalCore: CGFloat = 0.17

    /// Animating `reach` lets SwiftUI interpolate the growth rather than
    /// snapping between frames.
    var animatableData: CGFloat {
        get { reach }
        set { reach = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 * max(reach, 0)
        var path = Path()

        func circle(_ radius: CGFloat) {
            path.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2))
        }

        guard spokes > 0, outer > 0 else {
            circle(outer)
            return path
        }
        if style == .petal { circle(outer * Self.petalCore) }

        for index in 0..<spokes {
            // Quarter turn back so an arm points straight up, whatever the
            // spoke count: the mark is read upright, and an even count would
            // otherwise sit on its side.
            let angle = 2 * .pi * CGFloat(index) / CGFloat(spokes) - .pi / 2
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
            switch style {
            case .ray:
                let width = outer * Self.rayWidth
                // Started behind the centre so opposing arms meet cleanly
                // instead of leaving a seam where they butt together.
                let arm = CGRect(
                    x: -width / 2, y: -width / 2, width: outer + width / 2, height: width)
                path.addPath(
                    Path(roundedRect: arm, cornerRadius: width / 2), transform: transform)
            case .petal:
                let inset = outer * Self.petalInset
                let width = outer * Self.petalWidth
                let petal = CGRect(
                    x: inset, y: -width / 2, width: outer - inset, height: width)
                path.addPath(Path(ellipseIn: petal), transform: transform)
            }
        }
        return path
    }
}

// MARK: - Dot grids

/// Cursor's mark: a three by three grid with a band of dots sweeping around
/// it. Eight steps read off the `cursor-agent` console spinner. Colour comes
/// from the row accent (``monochromeAccent``), not a brand olive, so the
/// dots share ink with Codex and Antigravity and are told apart by shape.
enum CursorDots {
    static let grid = DotMatrix.Grid(columns: 3, rows: 3)

    /// Transcribed step by step rather than derived, because the band is not a
    /// plain rotation: it thins and thickens as it goes round.
    static let frames: [[Bool]] = [
        DotMatrix.mask("..#", "..#", "##."),
        DotMatrix.mask("...", "#.#", "#.#"),
        DotMatrix.mask("#..", "#..", ".##"),
        DotMatrix.mask("#..", "##.", ".#."),
        DotMatrix.mask("##.", "##.", "..#"),
        DotMatrix.mask(".#.", "###", "#.#"),
        DotMatrix.mask(".##", ".##", "#.."),
        DotMatrix.mask("..#", ".##", ".#."),
    ]
}

/// Grok's mark: the braille spinner, a two by three cell with three or four
/// dots chasing round its edge. Eight steps read off the `grok` console
/// spinner, which is the familiar `⠋⠙⠹⠸⠼⠴⠦⠧` cycle drawn out rather than typed.
enum GrokDots {
    static let grid = DotMatrix.Grid(columns: 2, rows: 3)

    static let frames: [[Bool]] = [
        DotMatrix.mask("##", "#.", ".."),
        DotMatrix.mask("##", ".#", ".."),
        DotMatrix.mask("##", ".#", ".#"),
        DotMatrix.mask(".#", ".#", ".#"),
        DotMatrix.mask(".#", ".#", "##"),
        DotMatrix.mask("..", ".#", "##"),
        DotMatrix.mask("..", "#.", "##"),
        DotMatrix.mask("#.", "#.", "##"),
    ]
}

/// Antigravity's mark: a full two by four braille cell with one dot punched
/// out, the hole orbiting the cell's edge. Close kin to Grok's, and deliberately
/// not shared with it: Grok lights three or four dots of a shorter two by three
/// cell and reads as sparse dots chasing, while this is a solid block with a
/// gap running round it, in a taller cell and half again as quick. Sharing one
/// mark between two tools would have cost the thing the marks are for, which is
/// telling at a glance which tool is busy.
///
/// Eight steps, the hole walking the perimeter clockwise. Seven were read off
/// the `agy` console spinner directly; the eighth is the only position the
/// perimeter leaves unaccounted for, and it falls in the recording's one
/// dropped frame (its 0.134s gap against a 0.093s step).
enum AntigravityDots {
    static let grid = DotMatrix.Grid(columns: 2, rows: 4)

    static let frames: [[Bool]] = [
        DotMatrix.mask(".#", "##", "##", "##"),
        DotMatrix.mask("#.", "##", "##", "##"),
        DotMatrix.mask("##", "#.", "##", "##"),
        DotMatrix.mask("##", "##", "#.", "##"),
        DotMatrix.mask("##", "##", "##", "#."),
        DotMatrix.mask("##", "##", "##", ".#"),
        DotMatrix.mask("##", "##", ".#", "##"),
        DotMatrix.mask("##", ".#", "##", "##"),
    ]
}

/// One step of a dot-grid mark: square dots on a fixed pitch, the shape a
/// terminal cell draws. The pitch comes from the grid's longer side, so a
/// narrow grid keeps the same dot size as a square one and simply occupies
/// less width, centred in the row's footprint.
struct DotMatrix: View {
    struct Grid {
        let columns: Int
        let rows: Int
    }

    let grid: Grid
    /// Which cells are lit, row-major from the top left.
    let lit: [Bool]

    /// Reads a step written out as rows of `#` and `.`, which keeps the frame
    /// tables legible as the picture they are.
    static func mask(_ rows: String...) -> [Bool] {
        rows.flatMap { $0.map { $0 == "#" } }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let step = side / CGFloat(max(grid.columns, grid.rows))
            let dot = step * 0.62
            let inset = (step - dot) / 2
            // Centre the grid: a 2-wide grid in a 3-wide footprint would sit
            // off to the left otherwise, and the row's dots must line up with
            // every other row's.
            let originX = (geometry.size.width - step * CGFloat(grid.columns)) / 2
            let originY = (geometry.size.height - step * CGFloat(grid.rows)) / 2
            ForEach(0..<(grid.columns * grid.rows), id: \.self) { index in
                if lit[index] {
                    RoundedRectangle(cornerRadius: dot * 0.22, style: .continuous)
                        .frame(width: dot, height: dot)
                        .offset(
                            x: originX + CGFloat(index % grid.columns) * step + inset,
                            y: originY + CGFloat(index / grid.columns) * step + inset)
                }
            }
        }
    }
}

// MARK: - Core Animation playback

/// Each sprite's frames as white mask images, drawn once per sprite and
/// backing scale, then reused by every row that shows that tool.
@MainActor
private enum SpriteMasks {
    private static var cache: [String: [CGImage]] = [:]

    static func frames(for sprite: AgentSprite, scale: CGFloat) -> [CGImage] {
        let key = "\(sprite)-\(scale)"
        if let cached = cache[key] { return cached }
        let images = (0..<sprite.frameCount).compactMap { index -> CGImage? in
            let renderer = ImageRenderer(content:
                sprite.frame(at: index)
                    .foregroundStyle(Color.white)
                    .frame(width: 12, height: 12))
            renderer.scale = scale
            return renderer.cgImage
        }
        cache[key] = images
        return images
    }
}

/// A layer filled with the tint, masked by the sprite's current frame, the
/// frames stepped by a repeating discrete keyframe animation.
private struct SpriteLayerView: NSViewRepresentable {
    var sprite: AgentSprite
    var tint: Color

    func makeNSView(context: Context) -> SpriteView { SpriteView() }

    func updateNSView(_ view: SpriteView, context: Context) {
        view.show(sprite, tint: NSColor(tint))
    }
}

private final class SpriteView: NSView {
    private let mask = CALayer()
    private var sprite: AgentSprite?
    private var tint: NSColor = .labelColor
    private var scale: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        restart()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    @MainActor func show(_ sprite: AgentSprite, tint: NSColor) {
        self.tint = tint
        applyTint()
        guard sprite != self.sprite else { return }
        self.sprite = sprite
        restart()
    }

    private func applyTint() {
        // Resolve dynamic colours against this view's appearance.
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = self.tint.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color
        CATransaction.commit()
    }

    @MainActor private func restart() {
        guard let sprite else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        self.scale = scale
        let frames = SpriteMasks.frames(for: sprite, scale: scale)
        mask.removeAllAnimations()
        mask.contents = frames.first
        guard frames.count > 1 else { return }
        let step = CAKeyframeAnimation(keyPath: "contents")
        step.values = frames
        step.calculationMode = .discrete
        step.duration = sprite.frameInterval * Double(frames.count)
        step.repeatCount = .infinity
        mask.add(step, forKey: "frames")
    }
}
