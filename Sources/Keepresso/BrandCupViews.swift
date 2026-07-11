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
    /// The battery pause: the idle cup with a last sip of coffee pooled at
    /// the bottom in the system's low-power yellow, the last of the charge.
    /// The sip is the only colored ink, subtle but unambiguous next to the
    /// plain idle outline. Not a template image (a template would flatten
    /// the yellow); the strokes use the dynamic label color so they match
    /// the bar in both appearances. Same canvas as the other states, which
    /// also avoids the status item's refusal to widen for changed label
    /// content (see ``MenuBarLabel``).
    static let pausedLowBattery = renderPausedLowBattery()

    private static func render(active: Bool) -> NSImage {
        let side = BrandCupMark.grid
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            if !active {
                // No steam in this state, so don't reserve its headroom: grow
                // the cup a touch and center its ink in the canvas, keeping
                // the glyph's optical size in line with neighboring icons.
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
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The last sip's footprint in the mark's grid, shared with
    /// ``BrandCupGlyph`` so the menu header shows the same pool.
    static let lowSipRect = CGRect(x: 2.8, y: 10.5, width: 10.2, height: 2.2)

    /// The idle cup with a small yellow pool of coffee left at the bottom.
    private static func renderPausedLowBattery() -> NSImage {
        let side = BrandCupMark.grid
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.labelColor.cgColor)

            // Recentered like the idle cup (no steam headroom to reserve).
            let ink = BrandCupMark.cupInk
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.scaleBy(x: 1.1, y: 1.1)
            ctx.translateBy(x: -ink.midX, y: -ink.midY)

            // The last sip, clipped to the cup's rounded bottom.
            ctx.saveGState()
            ctx.addPath(BrandCupMark.cup())
            ctx.clip()
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.fill(Self.lowSipRect)
            ctx.restoreGState()

            ctx.setLineWidth(BrandCupMark.outlineWidth)
            ctx.addPath(BrandCupMark.cup())
            ctx.strokePath()
            ctx.addPath(BrandCupMark.handle())
            ctx.strokePath()

            ctx.setLineWidth(BrandCupMark.saucerWidth)
            ctx.addPath(BrandCupMark.saucer())
            ctx.strokePath()
            return true
        }
        image.isTemplate = false
        return image
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
    /// Show the battery pause's last sip: a small yellow pool at the bottom
    /// of the (otherwise empty) cup, matching ``MenuBarIcon/pausedLowBattery``
    /// so the menu header and the bar tell the same story.
    var lowSip = false

    init(filled: Bool, lowSip: Bool = false) {
        fill = filled ? 1 : 0
        self.lowSip = lowSip
    }
    init(fill: CGFloat, lowSip: Bool = false) {
        self.fill = min(1, max(0, fill))
        self.lowSip = lowSip
    }

    var body: some View {
        GeometryReader { geo in
            let ink = BrandCupMark.cupInk
            let scale = min(geo.size.width / ink.width, geo.size.height / ink.height)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -ink.minX, y: -ink.minY)

            ZStack {
                if lowSip {
                    // Under the outline, clipped to the cup's rounded bottom.
                    Path(BrandCupMark.cup()).applying(transform)
                        .fill(Color(nsColor: .systemYellow))
                        .mask {
                            Path(MenuBarIcon.lowSipRect).applying(transform)
                                .fill(.black)
                        }
                }
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
