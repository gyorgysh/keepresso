// Exports BrandCupMark as a custom SF Symbol SVG for the widget extension's
// asset catalog (Control Center controls only render symbol images, so the
// brand cup must be a real symbol there).
//
// Regenerate after changing the mark's geometry:
//   swiftc scripts/make-symbol.swift Sources/Keepresso/BrandCupMark.swift -o /tmp/make-symbol
//   /tmp/make-symbol > "Sources/KeepressoWidget/Assets.xcassets/keepresso.cup.symbolset/keepresso.cup.svg"
//
// The strokes (handle, saucer, steam) are flattened to filled outlines and the
// crema stripe is punched with the even-odd rule, so the symbol needs no
// stroke support from the renderer.

import CoreGraphics
import Foundation

@main
struct MakeSymbol {
    static func main() {
        /// The three scale variants actool requires, each in its own band.
        /// The system rescales anyway, so the bands share one glyph size.
        let bandHeight: CGFloat = 130
        let scales: [(name: String, capline: CGFloat)] = [
            ("S", 126), ("M", 426), ("L", 726),
        ]
        let canvas: CGFloat = 400
        let canvasHeight: CGFloat = 1000

        let ink = BrandCupMark.fullInk
        // Overshoot the cap-to-baseline band like real SF Symbols do: fitting
        // the band exactly renders noticeably smaller than neighboring system
        // glyphs (Control Center made the cup look tiny at 1.0).
        let glyphScale = bandHeight * 1.3 / ink.height
        let margin = ink.width * glyphScale * 0.08
        let left = canvas / 2 - ink.width * glyphScale / 2 - margin
        let right = canvas / 2 + ink.width * glyphScale / 2 + margin

        func fills(baseline: CGFloat) -> [(d: String, rule: String)] {
            let tx = canvas / 2 - ink.midX * glyphScale
            // Centered on the band's midline (not sitting on the baseline),
            // so the overshoot spreads evenly above and below.
            let ty = (baseline - bandHeight / 2) - ink.midY * glyphScale
            var transform = CGAffineTransform(translationX: tx, y: ty)
                .scaledBy(x: glyphScale, y: glyphScale)

            // Cup with the crema stripe punched out (even-odd: the stripe
            // sits fully inside the cup, so it reads as a hole).
            let cupAndCrema = CGMutablePath()
            cupAndCrema.addPath(BrandCupMark.cup())
            cupAndCrema.addPath(BrandCupMark.crema())

            var result: [(d: String, rule: String)] = [
                (svgPathData(cupAndCrema.copy(using: &transform)!), "evenodd"),
                (svgPathData(stroked(BrandCupMark.handle(), width: BrandCupMark.outlineWidth).copy(using: &transform)!), "nonzero"),
                (svgPathData(stroked(BrandCupMark.saucer(), width: BrandCupMark.saucerWidth).copy(using: &transform)!), "nonzero"),
            ]
            for wisp in BrandCupMark.steamWisps() {
                result.append((svgPathData(stroked(wisp, width: BrandCupMark.steamWidth).copy(using: &transform)!), "nonzero"))
            }
            return result
        }

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg width="\(Int(canvas))" height="\(Int(canvasHeight))" xmlns="http://www.w3.org/2000/svg">
         <g id="Notes"/>
         <g id="Guides">

        """
        for band in scales {
            let baseline = band.capline + bandHeight
            svg += "  <line id=\"Baseline-\(band.name)\" x1=\"0\" y1=\"\(Int(baseline))\" x2=\"\(Int(canvas))\" y2=\"\(Int(baseline))\"/>\n"
            svg += "  <line id=\"Capline-\(band.name)\" x1=\"0\" y1=\"\(Int(band.capline))\" x2=\"\(Int(canvas))\" y2=\"\(Int(band.capline))\"/>\n"
        }
        svg += """
          <line id="left-margin" x1="\(String(format: "%.2f", left))" y1="\(Int(scales[0].capline))" x2="\(String(format: "%.2f", left))" y2="\(Int(scales[0].capline + bandHeight))"/>
          <line id="right-margin" x1="\(String(format: "%.2f", right))" y1="\(Int(scales[0].capline))" x2="\(String(format: "%.2f", right))" y2="\(Int(scales[0].capline + bandHeight))"/>
         </g>
         <g id="Symbols">

        """
        for band in scales {
            svg += "  <g id=\"Regular-\(band.name)\">\n"
            for fill in fills(baseline: band.capline + bandHeight) {
                svg += "   <path d=\"\(fill.d)\" fill-rule=\"\(fill.rule)\"/>\n"
            }
            svg += "  </g>\n"
        }
        svg += """
         </g>
        </svg>
        """

        print(svg)
    }

    static func svgPathData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { element in
        let p = element.pointee.points
        func fmt(_ pt: CGPoint) -> String {
            String(format: "%.2f %.2f", pt.x, pt.y)
        }
        switch element.pointee.type {
        case .moveToPoint: d += "M \(fmt(p[0])) "
        case .addLineToPoint: d += "L \(fmt(p[0])) "
        case .addQuadCurveToPoint: d += "Q \(fmt(p[0])) \(fmt(p[1])) "
        case .addCurveToPoint: d += "C \(fmt(p[0])) \(fmt(p[1])) \(fmt(p[2])) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
        return d.trimmingCharacters(in: .whitespaces)
    }

    static func stroked(_ path: CGPath, width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }
}
