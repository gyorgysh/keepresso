import SwiftUI
import AppKit

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
    static let hidden: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: BrandCupMark.grid), flipped: true) { _ in true }
        image.isTemplate = true
        return image
    }()

    private static func render(active: Bool) -> NSImage {
        let side = BrandCupMark.grid
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            if !active {
                let ink = BrandCupMark.cupInk
                ctx.translateBy(x: side / 2, y: side / 2)
                ctx.scaleBy(x: 1.1, y: 1.1)
                ctx.translateBy(x: -ink.midX, y: -ink.midY)
            }

            if active {
                ctx.addPath(BrandCupMark.cup())
                ctx.fillPath()
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

    static let lowSipRect = CGRect(x: 2.8, y: 10.5, width: 10.2, height: 2.2)

    private static func renderPausedLowBattery() -> NSImage {
        let side = BrandCupMark.grid
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.labelColor.cgColor)

            let ink = BrandCupMark.cupInk
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.scaleBy(x: 1.1, y: 1.1)
            ctx.translateBy(x: -ink.midX, y: -ink.midY)

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

struct BrandCupGlyph: View {
    var fill: CGFloat
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
                    Path(BrandCupMark.cup()).applying(transform)
                        .fill(Color(nsColor: .systemYellow))
                        .mask {
                            Path(MenuBarIcon.lowSipRect).applying(transform)
                                .fill(.black)
                        }
                }
                Group {
                    Path(BrandCupMark.cupAndHandle()).applying(transform)
                        .stroke(Color.secondary, style: .init(lineWidth: BrandCupMark.outlineWidth * scale, lineCap: .round))
                    Path(BrandCupMark.saucer()).applying(transform)
                        .stroke(Color.secondary, style: .init(lineWidth: BrandCupMark.saucerWidth * scale, lineCap: .round))
                }
                .opacity(outlineOpacity)

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

    private var outlineOpacity: Double {
        fill <= 0.75 ? 1 : Double((1 - fill) / 0.25)
    }
}
