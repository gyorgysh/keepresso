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
    var agent: String?
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
        .frame(width: 12, height: 12)
    }
}

struct RestDot: View {
    static let diameter: CGFloat = 3.1

    var body: some View {
        Circle().frame(width: Self.diameter, height: Self.diameter)
    }
}

enum AgentSprite {
    case claudeSunburst
    case cursorDots
    case grokDots
    case breathingDot
    case antigravityDots

    var frameInterval: TimeInterval {
        switch self {
        case .claudeSunburst: return 0.13
        case .cursorDots: return 0.25
        case .grokDots: return 0.13
        case .breathingDot: return 0.094
        case .antigravityDots: return 0.093
        }
    }

    var frameCount: Int {
        switch self {
        case .claudeSunburst: return SunburstPulse.frames.count
        case .cursorDots: return CursorDots.frames.count
        case .grokDots: return GrokDots.frames.count
        case .breathingDot: return BreathingDot.frames.count
        case .antigravityDots: return AntigravityDots.frames.count
        }
    }

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

enum BreathingDot {
    static let frames: [Double] = [
        1.00, 1.00, 0.92, 0.66, 0.37, 0.16, 0.09, 0.16, 0.37, 0.66, 0.92,
    ]

    static func view(_ opacity: Double) -> some View {
        RestDot().opacity(opacity)
    }
}


enum SunburstPulse {
    struct Frame {
        let spokes: Int
        let style: Sunburst.Style
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

struct Sunburst: Shape {
    enum Style {
        case ray
        case petal
    }

    var spokes: Int
    var style: Style
    var reach: CGFloat

    private static let rayWidth: CGFloat = 0.21
    private static let petalInset: CGFloat = 0.32
    private static let petalWidth: CGFloat = 0.38
    private static let petalCore: CGFloat = 0.17

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
            let angle = 2 * .pi * CGFloat(index) / CGFloat(spokes) - .pi / 2
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
            switch style {
            case .ray:
                let width = outer * Self.rayWidth
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


enum CursorDots {
    static let grid = DotMatrix.Grid(columns: 3, rows: 3)

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

struct DotMatrix: View {
    struct Grid {
        let columns: Int
        let rows: Int
    }

    let grid: Grid
    let lit: [Bool]

    static func mask(_ rows: String...) -> [Bool] {
        rows.flatMap { $0.map { $0 == "#" } }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let step = side / CGFloat(max(grid.columns, grid.rows))
            let dot = step * 0.62
            let inset = (step - dot) / 2
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
