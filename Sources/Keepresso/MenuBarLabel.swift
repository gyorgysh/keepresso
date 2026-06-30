import SwiftUI
import KeepressoCore

/// The icon shown in the system menu bar: a filled cup while brewing, an outline
/// cup while idle.
///
/// While brewing it animates with a `.symbolEffect` "brewing" shimmer. We use an
/// SF Symbol rather than a custom `Canvas`/`TimelineView`: a `MenuBarExtra` label
/// is snapshotted to a template image, so a Canvas renders blank and arbitrary
/// SwiftUI animations don't run — `.symbolEffect` is the one animation the menu
/// bar honours.
struct MenuBarLabel: View {
    @Bindable var session: SessionController

    var body: some View {
        Image(systemName: session.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: session.isActive
            )
            .accessibilityLabel(session.isActive ? "Keepresso: brewing" : "Keepresso: idle")
    }
}
