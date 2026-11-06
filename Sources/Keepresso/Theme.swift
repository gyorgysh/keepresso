import SwiftUI
import AppKit

extension Color {
    /// The brewing/active accent, matching the website's burnt-copper palette:
    /// burnt copper (#A64B23) in light mode, soft copper (#D98F52) in dark.
    static let keepressoBrew = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 217 / 255, green: 143 / 255, blue: 82 / 255, alpha: 1)
            : NSColor(srgbRed: 166 / 255, green: 75 / 255, blue: 35 / 255, alpha: 1)
    })

    /// The secondary copper tone, used for the steam in ``BrewingCupView``:
    /// a deeper, redder companion to the accent. #8F3F1C in light mode
    /// (the website's hover/strong copper), #D0824A in dark.
    static let keepressoSteam = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 208 / 255, green: 130 / 255, blue: 74 / 255, alpha: 1)
            : NSColor(srgbRed: 143 / 255, green: 63 / 255, blue: 28 / 255, alpha: 1)
    })

    /// Claude's terracotta, used to tint claude session rows: #D97757 in dark
    /// mode (the Claude Code console spinner), the deeper #C15F3C in light.
    static let claudeAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
            : NSColor(srgbRed: 193 / 255, green: 95 / 255, blue: 60 / 255, alpha: 1)
    })

    /// For tools whose mark is monochrome (Grok, Codex, Cursor, Antigravity):
    /// tint their rows with the menu's own ink rather than a hue, near-black
    /// on light and near-white on dark. Pulled a little off pure black and
    /// white so a working row still reads as tinted next to ordinary label
    /// text. Their marks are told apart by shape, not color.
    static let monochromeAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 242 / 255, alpha: 1)
            : NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)
    })
}

private extension NSAppearance {
    var isDarkAppearance: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A small (i) button that pops an explanation over the control it sits next
/// to: room for the "how and why" that would clutter a menu row as a caption
/// (what a switch flips, when a password is needed, how the administrator
/// helper makes it silent).
struct InfoButton: View {
    /// Already-localized popover text (compose with `L(...)`).
    let text: String
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("Learn more"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280)
        }
    }
}

/// A Form section header with an ``InfoButton`` after the title. The pairing is
/// the rule for Preferences: the section's footer stays one plain line saying
/// what the setting does, and the popover carries the detail (how it works, what
/// it costs, when it doesn't apply) that used to make footers a wall of text.
func sectionHeader(_ title: LocalizedStringKey, info: String) -> some View {
    HStack(spacing: 4) {
        Text(title)
        InfoButton(text: info)
    }
}

/// A one-line section footer, the short half of the ``sectionHeader`` pairing.
func sectionFooter(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

/// A switch row that pushes the control to the container's trailing edge, so
/// stacked switches line up in one column instead of each trailing its own
/// label width. For plain stacks; grouped Forms already align their controls.
/// Sized small to match the switches in the grouped Preferences forms, so
/// every switch in the app renders at one size. An optional `info` text adds
/// an ``InfoButton`` after the label.
/// `switchLocked` freezes only the switch, for a setting something else is
/// driving. The label and its ``InfoButton`` stay live (the explanation is
/// exactly what a user reaches for then), and a click on the dead switch calls
/// `onLockedTap` instead of being swallowed.
func switchRow(
    _ title: LocalizedStringKey,
    isOn: Binding<Bool>,
    info: String? = nil,
    switchLocked: Bool = false,
    onLockedTap: (() -> Void)? = nil
) -> some View {
    let label = HStack(spacing: 4) {
        Text(title)
        if let info {
            InfoButton(text: info)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

    return Group {
        if switchLocked {
            HStack(spacing: 8) {
                label
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .disabled(true)
                    // A disabled control takes no clicks, so catch them above it.
                    .overlay {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { onLockedTap?() }
                    }
            }
        } else {
            Toggle(isOn: isOn) { label }
        }
    }
    .toggleStyle(.switch)
    .controlSize(.small)
}

/// A short sideways shake, driven by a counter: each bump animates one shake.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three passes either side of centre, landing back on centre as the
        // value reaches the next whole number.
        ProjectionTransform(CGAffineTransform(
            translationX: 5 * sin(animatableData * .pi * 6), y: 0
        ))
    }
}

/// Wraps ``ShakeEffect`` so the motion can be skipped under Reduce Motion,
/// which needs an environment read and so can't live in a plain modifier.
private struct Shake: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(animatableData: reduceMotion ? 0 : CGFloat(count)))
            .animation(reduceMotion ? nil : .linear(duration: 0.3), value: count)
    }
}

extension View {
    /// Shake this view whenever `count` changes. Point it at the line that
    /// explains why a control is inert, so a click on that control draws the
    /// eye to the answer instead of doing nothing.
    func shakes(on count: Int) -> some View {
        modifier(Shake(count: count))
    }
}

/// A plain, full-width menu row: no border, a subtle hover/press highlight, and
/// left-aligned text, closer to a native menu item than the default `.bordered`
/// pill button style, so it stays visually quiet next to prominent actions.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlight)
                )
                // Ease the hover highlight in and out; presses stay instant
                // (the value below changes without an animation) so clicks
                // keep their immediate feel.
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }

        private var highlight: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            return isHovering ? Color.primary.opacity(0.1) : .clear
        }
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}

/// How much to grow the app's own surfaces (the menu panel, the welcome
/// window) for readability on very dense screens: native 4K/5K modes and
/// laptop "More Space" modes pack so many points per inch that a point is
/// physically tiny. The factor is the screen's points-per-inch over the
/// ~135 that Apple's densest default modes reach, so every normal
/// configuration stays at exactly 1; capped so nothing balloons.
enum Readability {
    static func scale(for screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return 1 }
        let millimeters = CGDisplayScreenSize(CGDirectDisplayID(truncating: number))
        guard millimeters.width > 0 else { return 1 }
        let pointsPerInch = screen.frame.width / (millimeters.width / 25.4)
        return min(1.5, max(1, pointsPerInch / 135))
    }
}

/// The app's text styles at the readability scale. The fonts themselves
/// grow because nothing else works on macOS: dynamicTypeSize is a no-op
/// (verified empirically), and scaleEffect rasterizes, which blurs text
/// precisely on the dense 1x displays this exists for.
struct ScaledType {
    let scale: CGFloat

    init(scale: CGFloat = Readability.scale()) { self.scale = scale }

    private func size(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style, options: [:]).pointSize * scale
    }

    var body: Font { .system(size: size(.body)) }
    var headline: Font { .system(size: size(.headline), weight: .semibold) }
    var callout: Font { .system(size: size(.callout)) }
    var caption: Font { .system(size: size(.caption1)) }
    var caption2: Font { .system(size: size(.caption2)) }
    var title2: Font { .system(size: size(.title2)) }
    var title3: Font { .system(size: size(.title3)) }
}

/// Places the hosting window when it appears: centered on its screen,
/// ordered front, and made key with the app activated. Keepresso is a
/// background agent (LSUIElement), so a plain window open can land behind
/// the active app and wherever macOS last left the frame. One shot, at open
/// only; the window level stays normal unless `floating`, so nothing keeps
/// blocking other windows afterwards.
struct WindowPlacement: NSViewRepresentable {
    var floating = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if floating { window.level = .floating }
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            Self.repairIfWedged(window, attempts: 3)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Cooperative activation (macOS 14+) can leave a window opened from the
    /// menu in a wedged half-active state: AppKit reports the app active
    /// (`NSApp.isActive`) and may even report the window key, but the system
    /// never actually made the app frontmost (the workspace's
    /// `NSRunningApplication` view disagrees), so every control and material
    /// draws in the inactive gray style, and clicking inside the window
    /// restores nothing because AppKit sees no activation left to perform.
    /// Check a beat after opening and do programmatically what the user
    /// otherwise must do by hand: drop active status, take it again, re-key
    /// the window.
    ///
    /// Repair only fires on the wedge's exact signature (the two activation
    /// views disagreeing) or when the app is frontmost with no key window at
    /// all. When AppKit itself reports the app inactive, or another of our
    /// windows holds key, the user has moved on, and stealing focus back
    /// would be worse than the wedge.
    static func repairIfWedged(_ window: NSWindow?, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
            guard let window, window.isVisible, window.canBecomeKey else { return }
            let trulyActive = NSRunningApplication.current.isActive
            if NSApp.isActive && !trulyActive {
                NSApp.deactivate()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                repairIfWedged(window, attempts: attempts - 1)
            } else if trulyActive && !window.isKeyWindow && NSApp.keyWindow == nil {
                window.makeKeyAndOrderFront(nil)
                repairIfWedged(window, attempts: attempts - 1)
            }
        }
    }
}

extension View {
    /// Center the window and bring it to the front when it opens. Applied
    /// once per open; an already open window is left where the user put it.
    func centersAndFrontsWindow() -> some View {
        background(WindowPlacement())
    }

    /// Re-asserts key status on the menu-bar panel shortly after it opens.
    /// When the app is stuck in the half-active state (see
    /// ``WindowPlacement/repairIfWedged(_:attempts:)``), the panel can come
    /// up without key status and draw its whole surface in the inactive gray
    /// style. A plain `makeKey()` is enough here and never dismisses the
    /// panel, unlike a full deactivate/activate cycle.
    func keepsPanelKey() -> some View {
        background(PanelKeyAssert())
    }
}

/// The panel-side repair behind ``View/keepsPanelKey()``.
private struct PanelKeyAssert: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
            guard let window = view?.window, window.isVisible, window.canBecomeKey, !window.isKeyWindow else { return }
            window.makeKey()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The backing that keeps text readable over glass on any wallpaper: a material
/// for blur, plus a wash of the window background color so a very dark or busy
/// desktop can't pull the surface's luminance away from what the text color
/// expects (in light mode that wash is the "white lighting" layer). The wash is
/// translucent, so the surface still reads as glass.
///
/// Two strengths: the menu panel sits on the system's own panel chrome and
/// needs only a light touch; full windows show far more wallpaper, so they get
/// a stronger material and a heavier wash to stay readable in any environment.
/// The user's window-transparency choice (Preferences ▸ General ▸
/// Appearance), 0 = the frosted default, 1 = clearest glass. A process-wide
/// observable rather than a parameter, so every glass surface (the menu
/// panel and each window's plate) reads it in place and a slider change
/// re-renders them all live, with no plumbing through seven call sites.
@MainActor
@Observable
final class GlassClarity {
    static let shared = GlassClarity()
    var value: Double = 0
}

private struct GlassReadabilityPlate: View {
    var material: Material = .thinMaterial
    var washOpacity: Double = 0.28
    /// How much of the frosting survives at full clarity. The panel sits on
    /// the system's own glass chrome and can go nearly bare. A window's
    /// plate is all there is between the text and the wallpaper, so it
    /// keeps a higher floor even at 100% see-through.
    var clarityFloor: Double = 0.08
    /// nil follows the Appearance slider (the menu panel); a fixed value
    /// opts out (the windows, which always keep their full frosted plate:
    /// the setting is about the dropdown, and window text has nothing but
    /// this plate between it and the wallpaper).
    var fixedClarity: Double?

    var body: some View {
        let clarity = fixedClarity ?? GlassClarity.shared.value
        ZStack {
            Rectangle().fill(material)
                .opacity(1 - (1 - clarityFloor) * clarity)
            Color(nsColor: .windowBackgroundColor)
                .opacity(washOpacity * (1 - clarity))
        }
    }
}

/// The menu panel's backing, tuned so text over a busy window stays readable.
///
/// The thin SwiftUI material it replaces blurred too little: text in the
/// window behind the panel read straight through the rows. Three layers fix
/// that without losing the glass:
///
/// 1. A behind-window `NSVisualEffectView`, the material macOS itself puts
///    under window backgrounds. Its blur is far wider than a SwiftUI material,
///    so background detail dissolves into colour instead of showing as text.
/// 2. A neutral wash (black in dark mode, white in light) that sets a floor
///    under the text contrast whatever the desktop's brightness.
/// 3. A faint warm glow from the top, the brew colour, a little stronger
///    while brewing. It is a tint, not decoration: it keeps the panel from
///    reading as grey while leaving the rows neutral.
///
/// All three are static. The window server composites the blur, nothing here
/// animates or ticks, and when the panel is closed its window is off screen,
/// so the backing costs nothing at all.
///
/// The Appearance slider still applies: at 100% see-through the frost and
/// wash fall to a floor and the panel is close to the bare system glass.
/// Reduce Transparency gets an opaque window background.
private struct MenuPanelPlate: View {
    var brewing: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            let clarity = GlassClarity.shared.value
            let dark = colorScheme == .dark
            ZStack {
                BehindWindowFrost()
                    .opacity(1 - 0.7 * clarity)
                (dark ? Color.black : Color.white)
                    .opacity((dark ? 0.32 : 0.38) * (1 - 0.75 * clarity))
                EllipticalGradient(
                    stops: [
                        .init(color: Color.keepressoBrew.opacity((dark ? 0.16 : 0.08) * (brewing ? 1 : 0.55)), location: 0),
                        .init(color: Color.keepressoBrew.opacity((dark ? 0.05 : 0.025) * (brewing ? 1 : 0.55)), location: 0.55),
                        .init(color: .clear, location: 1),
                    ],
                    center: UnitPoint(x: 0.5, y: 0),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.9
                )
                PanelSteam(brewing: brewing, dark: dark)
            }
        }
    }
}

/// Steam drifting up the panel while it brews.
///
/// Built so the app does no work per frame. A seamless steam texture is
/// generated once, on the CPU, when the panel opens (a few milliseconds),
/// and Core Animation slides two copies of it upward at different speeds.
/// Core Animation runs those animations in the render server, so the app
/// itself sits idle while the steam moves. An earlier Metal shader version
/// redrew the effect in the app 24 times a second and cost a third of a core.
///
/// It stops entirely when it isn't seen: the panel's views exist only while
/// the panel is open, the animations are removed whenever the session isn't
/// brewing, and Reduce Motion and Low Power Mode keep it off.
private struct PanelSteam: View {
    var brewing: Bool
    var dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        SteamLayerView(running: brewing && !reduceMotion && !lowPower, dark: dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

private struct SteamLayerView: NSViewRepresentable {
    var running: Bool
    var dark: Bool

    func makeNSView(context: Context) -> SteamView { SteamView() }

    func updateNSView(_ view: SteamView, context: Context) {
        view.update(running: running, dark: dark)
    }
}

/// The layer tree behind ``PanelSteam``: a container faded toward the top,
/// holding two drifting layers of the same tile at different speeds,
/// mirrored, and strengths, so the wisps never visibly repeat.
private final class SteamView: NSView {
    private let container = CALayer()
    private let fade = CAGradientLayer()
    private let drifts = [CALayer(), CALayer()]
    private var running = false
    private var dark: Bool?
    private var tile: CGImage?
    /// The size the tiles were last laid out for. Layout passes at the same
    /// size (frequent, as the panel's rows change) leave the steam moving.
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(container)
        container.opacity = 0
        container.mask = fade
        // Thickest at the bottom, gone before the header.
        fade.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.45, 0.85]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        for (index, drift) in drifts.enumerated() {
            drift.opacity = index == 0 ? 1 : 0.6
            container.addSublayer(drift)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        fade.frame = bounds
        CATransaction.commit()
        if bounds.size != builtSize { rebuild() }
    }

    func update(running: Bool, dark: Bool) {
        if self.dark != dark {
            self.dark = dark
            tile = SteamTexture.make(dark: dark)
            rebuild()
        }
        guard running != self.running else { return }
        self.running = running
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        container.opacity = running ? 1 : 0
        CATransaction.setCompletionBlock { [weak self] in
            // Faded out: drop the animations so nothing moves unseen.
            guard let self, !self.running else { return }
            self.drifts.forEach { $0.removeAllAnimations() }
        }
        CATransaction.commit()
        if running { animate() }
    }

    /// Lays each drift out as a column of tiles tall enough to scroll one
    /// tile's height over the whole panel. Height changes reveal more of
    /// the same moving texture instead of stretching it and restarting it.
    private func rebuild() {
        guard let tile, bounds.width > 0, bounds.height > 0 else { return }
        builtSize = bounds.size
        let width = bounds.width
        let tileHeight = width * CGFloat(tile.height) / CGFloat(tile.width)
        let rowCount = Int(ceil(bounds.height / tileHeight)) + 2
        let widthChanged = drifts.first?.bounds.width != width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, drift) in drifts.enumerated() {
            // Do not assign frame while a transform animation is active.
            // Keep the bottom origin and texture scale independent of height.
            drift.bounds = CGRect(x: 0, y: 0, width: width, height: tileHeight * CGFloat(rowCount))
            drift.anchorPoint = .zero
            drift.position = CGPoint(x: 0, y: -tileHeight)
            while (drift.sublayers?.count ?? 0) > rowCount {
                drift.sublayers?.last?.removeFromSuperlayer()
            }
            while (drift.sublayers?.count ?? 0) < rowCount {
                drift.addSublayer(CALayer())
            }
            for (row, piece) in (drift.sublayers ?? []).enumerated() {
                piece.contents = tile
                piece.contentsGravity = .resize
                piece.frame = CGRect(x: 0, y: CGFloat(row) * tileHeight, width: width, height: tileHeight)
                // The second layer runs mirrored, so it never lines up with
                // the first.
                if index == 1 { piece.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) }
            }
        }
        CATransaction.commit()
        if widthChanged { drifts.forEach { $0.removeAllAnimations() } }
        if running { animate() }
    }

    private func animate() {
        guard bounds.height > 0, let first = drifts.first?.sublayers?.first else { return }
        let tileHeight = first.frame.height
        for (index, drift) in drifts.enumerated() {
            guard drift.animation(forKey: "rise") == nil else { continue }
            // Use a fixed, nonzero media-time origin so a width change or
            // resumed brew keeps its phase. Core Animation interprets a
            // zero beginTime as "start now" when the animation is added.
            let anchor = drift.convertTime(1, from: nil)
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = tileHeight
            rise.duration = index == 0 ? 26 : 41
            rise.repeatCount = .infinity
            rise.beginTime = anchor
            drift.add(rise, forKey: "rise")
            let sway = CABasicAnimation(keyPath: "transform.translation.x")
            sway.fromValue = index == 0 ? -8 : 10
            sway.toValue = index == 0 ? 8 : -10
            sway.duration = index == 0 ? 9 : 13
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sway.beginTime = anchor
            drift.add(sway, forKey: "sway")
        }
    }
}

/// A small, vertically seamless image of soft wisps: domain-warped value
/// noise whose lattice wraps in y, so stacked copies join without a seam.
/// Generated once per appearance and stretched to the panel, where its
/// softness is the point.
private enum SteamTexture {
    static let width = 96
    static let height = 192
    /// Lattice cells across one tile height at the first octave. Every later
    /// octave doubles it, so all of them wrap at the tile's edge.
    static let period = 6

    static func make(dark: Bool) -> CGImage? {
        // White in the dark; brew-tinted in the light, where white vanishes.
        // Resolved for the mode being built, not whatever appearance happens
        // to be current while this runs.
        var tint = NSColor.orange
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            tint = NSColor(Color.keepressoBrew).usingColorSpace(.deviceRGB) ?? .orange
        }
        let mix = dark ? 0.30 : 0.75
        let red = 1 - (1 - Double(tint.redComponent)) * mix
        let green = 1 - (1 - Double(tint.greenComponent)) * mix
        let blue = 1 - (1 - Double(tint.blueComponent)) * mix
        let peak = dark ? 0.10 : 0.12

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width) * 3
                let v = Double(y) / Double(height) * Double(period)
                // The warp only scales x: scaling y would break the wrap, and
                // a warp that wraps itself keeps the warped noise seamless.
                let warpX = fbm(u * 0.7, v)
                let warpY = fbm(u * 0.7 + 5.2, v)
                let n = fbm(u + warpX * 1.6, v + warpY * 1.6)
                let wisps = smoothstep(0.50, 0.80, n)
                // Soft at the sides of the panel.
                let side = smoothstep(0, 0.12, Double(x) / Double(width))
                    * smoothstep(1, 0.88, Double(x) / Double(width))
                let alpha = wisps * side * peak
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(min(255, red * alpha * 255))
                pixels[offset + 1] = UInt8(min(255, green * alpha * 255))
                pixels[offset + 2] = UInt8(min(255, blue * alpha * 255))
                pixels[offset + 3] = UInt8(min(255, alpha * 255))
            }
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    /// Value noise whose y lattice wraps every `wrap` cells.
    private static func noise(_ x: Double, _ y: Double, wrap: Int) -> Double {
        let cellX = Int(floor(x)), cellY = Int(floor(y))
        var fx = x - floor(x), fy = y - floor(y)
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        func at(_ cx: Int, _ cy: Int) -> Double {
            hash(cx, ((cy % wrap) + wrap) % wrap)
        }
        let top = at(cellX, cellY) + (at(cellX + 1, cellY) - at(cellX, cellY)) * fx
        let bottom = at(cellX, cellY + 1) + (at(cellX + 1, cellY + 1) - at(cellX, cellY + 1)) * fx
        return top + (bottom - top) * fy
    }

    /// Four octaves. The y input is in units of first-octave cells, so octave
    /// `o` wraps at `period << o` cells, exactly one tile height.
    private static func fbm(_ x: Double, _ y: Double) -> Double {
        var value = 0.0, amplitude = 0.5, frequency = 1.0
        for octave in 0..<4 {
            value += amplitude * noise(x * frequency + Double(octave) * 17.1, y * frequency,
                                       wrap: period << octave)
            frequency *= 2
            amplitude *= 0.5
        }
        return value
    }
}

/// The system's under-window-background material, blending with whatever is
/// behind the window. A background only: it never takes a click.
private struct BehindWindowFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // Always active: the panel is never the key window, and following
        // the window's state would grey the frost out while it is open.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// A translucent "glass" surface behind a view. On macOS 26+ this is the real
    /// Liquid Glass material, tinted faintly toward the window background color
    /// so its content keeps contrast over dark desktops; on earlier systems it
    /// falls back to a frosted `ultraThinMaterial`, which reads as glass too.
    /// Pass a `tint` for an accented card (the copper callouts, the warning
    /// banner); it replaces the neutral wash on both paths.
    ///
    /// `followsClarity` is for cards living inside the menu panel: their
    /// backing thins out with the Appearance slider alongside the panel's
    /// own plate, so a clear-glass panel doesn't show frosted rectangles
    /// floating over it. Cards in windows leave it off, like the windows
    /// themselves.
    @MainActor
    @ViewBuilder
    func glassCard(
        cornerRadius: CGFloat = 12, tint: Color? = nil, followsClarity: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let clarity = followsClarity ? GlassClarity.shared.value : 0
        let cardTint = (tint ?? Color(nsColor: .windowBackgroundColor).opacity(0.25))
            .opacity(1 - clarity)
        if #available(macOS 26.0, *) {
            // The Liquid Glass itself stays at full clarity (that IS the
            // clear look); only the readability tint fades away.
            self.glassEffect(.regular.tint(cardTint), in: shape)
        } else {
            // The tint sits behind the material, so it shows through the blur
            // softly instead of flat.
            self.background(shape.fill(.ultraThinMaterial).opacity(1 - 0.9 * clarity))
                .background(cardTint, in: shape)
        }
    }

    /// The style for a primary call to action: real Liquid Glass on macOS 26,
    /// the familiar bordered prominent button before. Both pick up the brew
    /// accent from the surrounding `tint`.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// A readability plate for the menu bar panel, layered over the system's
    /// glass chrome. The panel window itself owns the Liquid Glass; this adds
    /// blur and a faint neutral wash so the content stays sharp when the
    /// wallpaper behind the panel is very dark or high-contrast. Follows the
    /// Appearance slider: at 100% the plate all but vanishes and the panel
    /// is the system's bare Liquid Glass, at 0% it is fully frosty. The
    /// default sits at the halfway 50%.
    func glassPanelBackground(brewing: Bool = false) -> some View {
        background(MenuPanelPlate(brewing: brewing).ignoresSafeArea())
    }

    /// A translucent glass background for a whole window that stays readable on
    /// any desktop: the readability plate at window strength (stronger material
    /// and a heavier window-background wash than the menu panel, which sits on
    /// the system's own chrome and showed far less wallpaper). Uses the
    /// window-placement container background on macOS 15+ (a no-op on older
    /// systems, which keep the standard window chrome). Pair with
    /// `.scrollContentBackground(.hidden)` on any Form/List so the glass shows
    /// through instead of the form's opaque backing.
    @ViewBuilder
    func glassWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(for: .window) {
                // Thick + a strong wash: the menu panel composites its plate on
                // top of the system's own frosted chrome, but a window's plate
                // is all there is between the content and the wallpaper, so it
                // must supply that brightness itself to match the menu's look.
                GlassReadabilityPlate(
                    material: .thickMaterial, washOpacity: 0.6, fixedClarity: 0
                )
            }
        } else {
            self
        }
    }
}
