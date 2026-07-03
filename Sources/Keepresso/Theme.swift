import SwiftUI
import AppKit

extension Color {
    /// The brewing/active accent, matching the website's coffee palette and the
    /// app icon: caramel (#B45309) in light mode, warm amber (#E8A35C) in dark.
    static let keepressoBrew = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 232 / 255, green: 163 / 255, blue: 92 / 255, alpha: 1)
            : NSColor(srgbRed: 180 / 255, green: 83 / 255, blue: 9 / 255, alpha: 1)
    })

    /// The secondary copper tone, used for the steam in ``BrewingCupView``:
    /// #C2410C in light mode, #D97A4A in dark.
    static let keepressoSteam = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkAppearance
            ? NSColor(srgbRed: 217 / 255, green: 122 / 255, blue: 74 / 255, alpha: 1)
            : NSColor(srgbRed: 194 / 255, green: 65 / 255, blue: 12 / 255, alpha: 1)
    })
}

private extension NSAppearance {
    var isDarkAppearance: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A plain, full-width menu row: no border, a subtle hover/press highlight, and
/// left-aligned text — closer to a native menu item than the default `.bordered`
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
                        .fill(isHovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}

/// The backing that keeps text readable over glass on any wallpaper: a material
/// for blur, plus a faint wash of the window background color so a very dark or
/// busy desktop can't pull the surface's luminance away from what the text
/// color expects. The wash is translucent, so the surface still reads as glass.
private struct GlassReadabilityPlate: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.thinMaterial)
            Color(nsColor: .windowBackgroundColor).opacity(0.28)
        }
    }
}

extension View {
    /// A translucent "glass" surface behind a view. On macOS 26+ this is the real
    /// Liquid Glass material, tinted faintly toward the window background color
    /// so its content keeps contrast over dark desktops; on earlier systems it
    /// falls back to a frosted `ultraThinMaterial`, which reads as glass too.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.25)),
                in: shape
            )
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// A readability plate for the menu bar panel, layered over the system's
    /// glass chrome. The panel window itself owns the Liquid Glass; this adds
    /// blur and a faint neutral wash so the content stays sharp when the
    /// wallpaper behind the panel is very dark or high-contrast.
    func glassPanelBackground() -> some View {
        background(GlassReadabilityPlate().ignoresSafeArea())
    }

    /// A translucent, vibrant glass background for a whole window, matching the
    /// menu's look while staying readable on any desktop (same plate as
    /// ``glassPanelBackground()``). Uses the window-placement container
    /// background on macOS 15+ (a no-op on older systems, which keep the
    /// standard window chrome). Pair with `.scrollContentBackground(.hidden)` on
    /// any Form/List so the glass shows through instead of the form's opaque
    /// backing.
    @ViewBuilder
    func glassWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(for: .window) {
                GlassReadabilityPlate()
            }
        } else {
            self
        }
    }
}
