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
}

private extension NSAppearance {
    var isDarkAppearance: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
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

/// The backing that keeps text readable over glass on any wallpaper: a material
/// for blur, plus a wash of the window background color so a very dark or busy
/// desktop can't pull the surface's luminance away from what the text color
/// expects (in light mode that wash is the "white lighting" layer). The wash is
/// translucent, so the surface still reads as glass.
///
/// Two strengths: the menu panel sits on the system's own panel chrome and
/// needs only a light touch; full windows show far more wallpaper, so they get
/// a stronger material and a heavier wash to stay readable in any environment.
private struct GlassReadabilityPlate: View {
    var material: Material = .thinMaterial
    var washOpacity: Double = 0.28

    var body: some View {
        ZStack {
            Rectangle().fill(material)
            Color(nsColor: .windowBackgroundColor).opacity(washOpacity)
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
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(tint ?? Color(nsColor: .windowBackgroundColor).opacity(0.25)),
                in: shape
            )
        } else {
            // The tint sits behind the material, so it shows through the blur
            // softly instead of flat.
            self.background(.ultraThinMaterial, in: shape)
                .background(tint ?? .clear, in: shape)
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
    /// wallpaper behind the panel is very dark or high-contrast.
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
                GlassReadabilityPlate(material: .thickMaterial, washOpacity: 0.6)
            }
        } else {
            self
        }
    }
}
