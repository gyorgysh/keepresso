import SwiftUI

extension Color {
    /// The gyorgy.sh brand periwinkle (#5B5BD6), used as the brewing/active accent
    /// and matching the app icon.
    static let keepressoBrew = Color(red: 0.357, green: 0.357, blue: 0.839)
}

extension View {
    /// A translucent "glass" surface behind a view. On macOS 26+ this is the real
    /// Liquid Glass material; on earlier systems it falls back to a frosted
    /// `ultraThinMaterial`, which reads as glass too.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// A translucent, vibrant glass background for a whole window, matching the
    /// menu's Liquid Glass look. Uses the window-placement container background
    /// on macOS 15+ (a no-op on older systems, which keep the standard window
    /// chrome). Pair with `.scrollContentBackground(.hidden)` on any Form/List so
    /// the glass shows through instead of the form's opaque backing.
    @ViewBuilder
    func glassWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.ultraThinMaterial, for: .window)
        } else {
            self
        }
    }
}
