import SwiftUI
import AppKit

/// The brand mark's cup geometry (espresso cup, crema stripe, handle, saucer,
/// steam wisps) redrawn on a compact 18-point grid sized for the menu bar.
/// This is the same mark `scripts/make-icon.swift` renders for the app icon,
/// with the steam shortened so the cup stays legible at menu bar size.
///
/// Both in-app renderings share these paths: ``MenuBarIcon`` rasterizes them
/// into a template `NSImage` for the menu bar, and ``BrandCupGlyph`` draws them
/// as SwiftUI `Path`s in the dropdown header.
enum BrandCupMark {
    /// The layout grid the paths below are defined in (y pointing down).
    static let grid: CGFloat = 18

    /// Stroke widths in grid units.
    static let outlineWidth: CGFloat = 1.2
    static let saucerWidth: CGFloat = 1.4
    static let steamWidth: CGFloat = 1.1

    /// The ink bounds of the cup, handle, and saucer (steam excluded), stroke
    /// extents included. ``BrandCupGlyph`` fits this rect to its frame, and
    /// the idle menu bar icon recenters it in the canvas (see ``MenuBarIcon``).
    static let cupInk = CGRect(x: 1.6, y: 5.0, width: 14.6, height: 11.0)

    /// Cup body: straight rim, rounded bottom. Filled while brewing, stroked
    /// as an outline while idle.
    static func cup() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2.8, y: 5.6))
        p.addLine(to: CGPoint(x: 13.0, y: 5.6))
        p.addLine(to: CGPoint(x: 13.0, y: 9.4))
        p.addArc(center: CGPoint(x: 9.7, y: 9.4), radius: 3.3,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 6.1, y: 12.7))
        p.addArc(center: CGPoint(x: 6.1, y: 9.4), radius: 3.3,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    /// The crema stripe near the rim, punched out of the filled cup so the
    /// mark's signature stripe survives even in a monochrome template image.
    static func crema() -> CGPath {
        CGPath(roundedRect: CGRect(x: 4.6, y: 7.0, width: 6.6, height: 1.25),
               cornerWidth: 0.625, cornerHeight: 0.625, transform: nil)
    }

    /// Handle on the right side (stroked).
    static func handle() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 13.0, y: 6.9))
        p.addLine(to: CGPoint(x: 13.6, y: 6.9))
        p.addArc(center: CGPoint(x: 13.6, y: 8.95), radius: 2.05,
                 startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 13.0, y: 11.0))
        return p
    }

    /// Cup body and handle as one path, for stroking the idle outline in a
    /// single operation: separate strokes in a translucent color would
    /// double-darken where they overlap.
    static func cupAndHandle() -> CGPath {
        let p = CGMutablePath()
        p.addPath(cup())
        p.addPath(handle())
        return p
    }

    /// Saucer line under the cup (stroked).
    static func saucer() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2.3, y: 15.3))
        p.addLine(to: CGPoint(x: 13.5, y: 15.3))
        return p
    }

    /// Three staggered S-curve wisps above the cup, shown only while brewing.
    /// Kept short so the cup stays the dominant form at menu bar size.
    static func steamWisps() -> [CGPath] {
        let wisps: [(x: CGFloat, top: CGFloat, length: CGFloat)] = [
            (4.9, 1.7, 3.2), (7.9, 0.9, 3.9), (10.9, 1.7, 3.2),
        ]
        return wisps.map { wisp in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: wisp.x, y: wisp.top))
            p.addCurve(
                to: CGPoint(x: wisp.x, y: wisp.top + wisp.length),
                control1: CGPoint(x: wisp.x - 1.3, y: wisp.top + wisp.length * 0.35),
                control2: CGPoint(x: wisp.x + 1.3, y: wisp.top + wisp.length * 0.55)
            )
            return p
        }
    }
}

/// Template images for the system menu bar, rendered from ``BrandCupMark``:
/// a filled cup with steam while brewing, an outline cup while idle. Template
/// (monochrome) so macOS tints them for the bar's appearance and highlight
/// state, exactly like an SF Symbol.
@MainActor
enum MenuBarIcon {
    static let idle = render(active: false)
    static let brewing = render(active: true)

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
}

/// The brand cup (body, handle, saucer, no steam) as a SwiftUI view for real
/// windows, where color runs normally: brew accent when filled, secondary as
/// an outline. ``BrewingCupView`` draws its own animated steam above this.
struct BrandCupGlyph: View {
    var filled: Bool

    var body: some View {
        GeometryReader { geo in
            let ink = BrandCupMark.cupInk
            let scale = min(geo.size.width / ink.width, geo.size.height / ink.height)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -ink.minX, y: -ink.minY)
            let color = filled ? Color.keepressoBrew : Color.secondary

            ZStack {
                if filled {
                    Path(BrandCupMark.cup()).applying(transform)
                        .fill(color)
                    Path(BrandCupMark.crema()).applying(transform)
                        .fill(.black)
                        .blendMode(.destinationOut)
                    Path(BrandCupMark.handle()).applying(transform)
                        .stroke(color, style: .init(lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                } else {
                    Path(BrandCupMark.cupAndHandle()).applying(transform)
                        .stroke(color, style: .init(lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                }
                Path(BrandCupMark.saucer()).applying(transform)
                    .stroke(color, style: .init(lineWidth: BrandCupMark.saucerWidth * scale, lineCap: .round))
            }
            .compositingGroup() // confine destinationOut to the glyph's layers
        }
    }
}
