import SwiftUI

/// The "thinking" glyph next to an agent session in the menu: the Claude Code
/// console spinner's asterisk morph, pulsing from a dot out to a starburst
/// and back while the session works. An idle session shows the rest frame
/// (the dot the pulse grows out of) statically, so every row shares one glyph
/// family and footprint and only motion and color mark the working one. Text
/// glyphs tinted by the row's foreground style, so it reads correctly in both
/// menu appearances.
///
/// Lives in the menu panel, which keeps its content alive while closed on
/// current macOS, so the timeline would keep ticking unseen. The call site
/// passes `animated: false` while the panel is off screen (see
/// `WindowVisibilityReader`), which drops the timeline entirely.
struct SparkView: View {
    /// One pulse out and back, at the console's cadence; the first frame is
    /// also the idle rest state.
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let frameInterval: TimeInterval = 0.12

    /// False renders the rest frame with no timeline behind it.
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.frameInterval)
                glyph(Self.frames[tick % Self.frames.count])
            }
        } else {
            glyph(Self.frames[0])
        }
    }

    private func glyph(_ frame: String) -> some View {
        Text(verbatim: frame)
            .font(.system(size: 11, weight: .semibold))
            // The glyphs differ in advance width; a fixed footprint keeps
            // the row text from shivering as they cycle.
            .frame(width: 12, height: 12, alignment: .center)
    }
}
