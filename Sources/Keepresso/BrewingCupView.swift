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

    /// Size multiplier over the menu-header size (22 pt wide). Everything
    /// scales together (paths, stroke widths, drift), so a window header can
    /// show the same mark large and still crisp.
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One full rise-and-dissolve cycle per wisp, staggered thirds apart.
    private static let loopDuration: TimeInterval = 3.4
    private static let wispDelays: [TimeInterval] = [0, 1.15, 2.3]

    var body: some View {
        VStack(spacing: 1 * scale) {
            steam
                .frame(width: 22 * scale, height: 9 * scale)
            BrandCupGlyph(filled: isActive)
                .frame(width: 22 * scale, height: 16.6 * scale)
        }
        .accessibilityHidden(true) // the header text next to it carries the status
    }

    @ViewBuilder
    private var steam: some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                wisps { delay in Self.wispState(at: now, delay: delay) }
            }
        } else if isActive {
            // Reduce Motion: steady mid-rise steam instead of movement.
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

    /// Opacity and vertical drift for one wisp at a moment in its loop,
    /// keyframed to match the website mark: fade in while rising from below,
    /// thin out past the midpoint, gone by the top.
    static func wispState(at time: TimeInterval, delay: TimeInterval) -> (opacity: Double, rise: CGFloat) {
        let phase = ((time + delay).truncatingRemainder(dividingBy: loopDuration)) / loopDuration
        let keys: [(phase: Double, opacity: Double, rise: CGFloat)] = [
            (0.00, 0.00, 2.5),
            (0.30, 0.85, 0.0),
            (0.65, 0.30, -2.5),
            (1.00, 0.00, -4.0),
        ]
        for i in 0 ..< keys.count - 1 where phase <= keys[i + 1].phase {
            let a = keys[i], b = keys[i + 1]
            let t = (phase - a.phase) / (b.phase - a.phase)
            // Ease in-out within each segment so the motion reads as drift, not ramps.
            let eased = t * t * (3 - 2 * t)
            return (
                opacity: a.opacity + (b.opacity - a.opacity) * eased,
                rise: a.rise + (b.rise - a.rise) * CGFloat(eased)
            )
        }
        return (opacity: 0, rise: keys.last!.rise)
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
