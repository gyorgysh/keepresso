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
func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, info: String? = nil) -> some View {
    Toggle(isOn: isOn) {
        HStack(spacing: 4) {
            Text(title)
            if let info {
                InfoButton(text: info)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .controlSize(.small)
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
            guard let window, window.isVisible else { return }
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
            guard let window = view?.window, window.isVisible, !window.isKeyWindow else { return }
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
    func glassPanelBackground() -> some View {
        background(GlassReadabilityPlate().ignoresSafeArea())
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
