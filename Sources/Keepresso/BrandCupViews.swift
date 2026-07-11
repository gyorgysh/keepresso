import SwiftUI
import AppKit

/// Template images for the system menu bar, rendered from ``BrandCupMark``:
/// a filled cup with steam while brewing, an outline cup while idle. Template
/// (monochrome) so macOS tints them for the bar's appearance and highlight
/// state, exactly like an SF Symbol.
@MainActor
enum MenuBarIcon {
    static let idle = render(active: false)
    static let brewing = render(active: true)
    /// The idle cup with a drained battery beside it, for the battery pause:
    /// without it the pause reads as a plain idle cup. One composite image
    /// rather than a second `Image` in the label's HStack, because the
    /// MenuBarExtra label's status item never widens for a conditionally
    /// added image, it just clips it (measured on macOS 26: adding an
    /// `Image(systemName:)` left the item at 23 pt, while swapping in a
    /// single wider NSImage resized it; added `Text` also resizes, which is
    /// why the countdown works).
    static let pausedLowBattery = render(active: false, lowBatteryBadge: true)

    private static func render(active: Bool, lowBatteryBadge: Bool = false) -> NSImage {
        let side = BrandCupMark.grid
        let width = lowBatteryBadge ? side + 12 : side
        let image = NSImage(size: NSSize(width: width, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            ctx.saveGState()
            if !active {
                // No steam in this state, so don't reserve its headroom: grow
                // the cup a touch and center its ink in the left side-by-side
                // cell, keeping the glyph's optical size in line with
                // neighboring icons.
                let ink = BrandCupMark.cupInk
                ctx.translateBy(x: side / 2, y: side / 2)
                ctx.scaleBy(x: 1.1, y: 1.1)
                ctx.translateBy(x: -ink.midX, y: -ink.midY)
            }

            if active {
                ctx.addPath(BrandCupMark.cup())
                ctx.fillPath()
                // Erase the crema stripe out of the fill (negative space).
                ctx.setBlendMode(.destinationOut)
                ctx.addPath(BrandCupMark.crema())
                ctx.fillPath()
                ctx.setBlendMode(.normal)

                ctx.setLineWidth(BrandCupMark.steamWidth)
                for wisp in BrandCupMark.steamWisps() {
                    ctx.addPath(wisp)
                    ctx.strokePath()
                }
            } else {
                ctx.setLineWidth(BrandCupMark.outlineWidth)
                ctx.addPath(BrandCupMark.cup())
                ctx.strokePath()
            }

            ctx.setLineWidth(BrandCupMark.outlineWidth)
            ctx.addPath(BrandCupMark.handle())
            ctx.strokePath()

            ctx.setLineWidth(BrandCupMark.saucerWidth)
            ctx.addPath(BrandCupMark.saucer())
            ctx.strokePath()
            ctx.restoreGState()

            if lowBatteryBadge { drawLowBattery(in: ctx, leftEdge: side + 1.5) }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A small outline battery with a thin charge sliver, drawn to the right
    /// of the cup and vertically centered on the cup's body.
    private static func drawLowBattery(in ctx: CGContext, leftEdge: CGFloat) {
        let body = CGRect(x: leftEdge, y: 6.6, width: 8.2, height: 4.8)
        ctx.setLineWidth(1.1)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.strokePath()
        // Terminal nub.
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: body.maxX + 0.7, y: body.midY - 0.9, width: 1.0, height: 1.8),
            cornerWidth: 0.5, cornerHeight: 0.5, transform: nil
        ))
        ctx.fillPath()
        // What little charge is left.
        ctx.fill(CGRect(x: body.minX + 1.1, y: body.minY + 1.1, width: 1.9, height: body.height - 2.2))
    }
}

/// The brand cup (body, handle, saucer, no steam) as a SwiftUI view for real
/// windows, where color runs normally: brew accent when filled, secondary as
/// an outline. `fill` is the pour level, 0 (empty outline) through 1 (the
/// solid brewing cup); animating it raises the brew inside the outline and
/// dissolves the outline near the brim, so starting a session reads as a
/// pour rather than a swap. ``BrewingCupView`` drives that animation and
/// draws its own steam above this.
struct BrandCupGlyph: View {
    var fill: CGFloat

    init(filled: Bool) { fill = filled ? 1 : 0 }
    init(fill: CGFloat) { self.fill = min(1, max(0, fill)) }

    var body: some View {
        GeometryReader { geo in
            let ink = BrandCupMark.cupInk
            let scale = min(geo.size.width / ink.width, geo.size.height / ink.height)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -ink.minX, y: -ink.minY)

            ZStack {
                // The empty cup, gone once the pour reaches the brim so the
                // full state matches the solid brewing mark exactly.
                Group {
                    Path(BrandCupMark.cupAndHandle()).applying(transform)
                        .stroke(Color.secondary, style: .init(lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                    Path(BrandCupMark.saucer()).applying(transform)
                        .stroke(Color.secondary, style: .init(lineWidth: BrandCupMark.saucerWidth * scale, lineCap: .round))
                }
                .opacity(outlineOpacity)

                // The brew, rising from the saucer up. The crema stripe and
                // the handle are revealed by the same rising mask.
                Group {
                    ZStack {
                        Path(BrandCupMark.cup()).applying(transform)
                            .fill(Color.keepressoBrew)
                        Path(BrandCupMark.crema()).applying(transform)
                            .fill(.black)
                            .blendMode(.destinationOut)
                        Path(BrandCupMark.handle()).applying(transform)
                            .stroke(Color.keepressoBrew, style: .init(lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                    }
                    .compositingGroup() // confine destinationOut to the brew's layers
                    Path(BrandCupMark.saucer()).applying(transform)
                        .stroke(Color.keepressoBrew, style: .init(lineWidth: BrandCupMark.saucerWidth * scale, lineCap: .round))
                }
                .mask {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().frame(height: geo.size.height * fill)
                    }
                }
            }
        }
    }

    /// The outline holds while the brew rises, then dissolves over the last
    /// quarter of the pour.
    private var outlineOpacity: Double {
        fill <= 0.75 ? 1 : Double((1 - fill) / 0.25)
    }
}
