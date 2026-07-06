#!/usr/bin/env swift
//
// make-icon.swift — generate Keepresso's app icon asset catalog.
//
// Renders the website's brand mark (espresso cup, crema stripe, handle, saucer,
// three steam wisps) on a warm squircle: crema paper in light mode, deep roast
// in dark mode, matching the site's coffee palette. Re-run after tweaking:
//
//   swift scripts/make-icon.swift
//
// Output: Sources/Keepresso/Assets.xcassets/AppIcon.appiconset/
//
import AppKit

// Resolve the repo root from this script's location.
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = root
    .appendingPathComponent("Sources/Keepresso/Assets.xcassets/AppIcon.appiconset")

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

/// The palette for one appearance, taken from the website's tokens.
struct IconPalette {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let cup: NSColor    // cup body, handle, saucer
    let crema: NSColor  // the stripe inside the cup
    let steam: NSColor
}

let lightPalette = IconPalette(
    backgroundTop: srgb(250, 245, 236),    // paper #FAF5EC
    backgroundBottom: srgb(238, 223, 196), // deeper crema
    cup: srgb(45, 32, 21),                 // dark roast ink
    crema: srgb(180, 83, 9),               // caramel #B45309
    steam: srgb(194, 65, 12)               // copper #C2410C
)

let darkPalette = IconPalette(
    backgroundTop: srgb(40, 30, 19),       // warm roast
    backgroundBottom: srgb(18, 14, 10),    // deep roast #120E0A
    cup: srgb(247, 241, 232),              // warm white ink #F7F1E8
    crema: srgb(232, 163, 92),             // amber #E8A35C
    steam: srgb(232, 163, 92)
)

/// The brand-mark geometry in the website SVG's 64-point grid (y pointing down).
/// Fills: cup body and crema stripe. Strokes: handle, saucer, steam wisps.
enum BrandMark {
    static func cup() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 16, y: 28))
        p.addLine(to: CGPoint(x: 44, y: 28))
        p.addLine(to: CGPoint(x: 44, y: 38))
        p.addArc(center: CGPoint(x: 35, y: 38), radius: 9,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 25, y: 47))
        p.addArc(center: CGPoint(x: 25, y: 38), radius: 9,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    static func crema() -> CGPath {
        CGPath(roundedRect: CGRect(x: 20, y: 31.5, width: 20, height: 3.4),
               cornerWidth: 1.7, cornerHeight: 1.7, transform: nil)
    }

    static func handle() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 44, y: 31.5))
        p.addLine(to: CGPoint(x: 46.5, y: 31.5))
        p.addArc(center: CGPoint(x: 46.5, y: 37.5), radius: 6,
                 startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 43, y: 43.5))
        return p
    }

    static func saucer() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 15, y: 52))
        p.addLine(to: CGPoint(x: 45, y: 52))
        return p
    }

    /// Three staggered S-curve wisps above the cup, like the site's hero mark.
    static func steamWisps() -> [CGPath] {
        [(22.5, 12.0), (30.0, 9.0), (37.5, 12.0)].map { (x, y) in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: y))
            p.addCurve(to: CGPoint(x: x, y: y + 9.5),
                       control1: CGPoint(x: x - 2.6, y: y + 3.2),
                       control2: CGPoint(x: x + 2.6, y: y + 5.0))
            return p
        }
    }
}

/// Draw the icon at a given pixel size straight into a bitmap (no `lockFocus`,
/// which is unreliable when run headless) and return PNG data.
func renderIcon(pixels: CGFloat, dark: Bool = false) -> Data {
    let px = Int(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.restoreGraphicsState() }

    let palette = dark ? darkPalette : lightPalette

    // macOS icons leave a transparent margin around a continuous-corner squircle.
    let inset = pixels * 0.085
    let body = NSRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)!
        .draw(in: squircle, angle: -90)

    // Map the mark's 64-point grid (y down) onto the icon, centered. The mark's
    // ink spans roughly y 7…54 in that grid, so the optical center holds.
    let ctx = gc.cgContext
    ctx.saveGState()
    let scale = pixels * 0.80 / 64
    let offset = (pixels - 64 * scale) / 2
    ctx.translateBy(x: offset, y: pixels - offset)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setLineCap(.round)

    ctx.setFillColor(palette.cup.cgColor)
    ctx.addPath(BrandMark.cup())
    ctx.fillPath()

    ctx.setFillColor(palette.crema.cgColor)
    ctx.addPath(BrandMark.crema())
    ctx.fillPath()

    ctx.setStrokeColor(palette.cup.cgColor)
    ctx.setLineWidth(3.4)
    ctx.addPath(BrandMark.handle())
    ctx.strokePath()

    ctx.setLineWidth(3.6)
    ctx.addPath(BrandMark.saucer())
    ctx.strokePath()

    ctx.setStrokeColor(palette.steam.cgColor)
    ctx.setLineWidth(3.2)
    for wisp in BrandMark.steamWisps() {
        ctx.addPath(wisp)
        ctx.strokePath()
    }
    ctx.restoreGState()

    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

/// One separable layer of the mark, for the Liquid Glass (Icon Composer) build.
enum IconLayer: String { case background, cup, steam }

/// Render a single layer onto its own canvas so Icon Composer can stack them
/// and apply the Liquid Glass material per layer. The background is full-bleed
/// (Icon Composer masks the icon shape); the cup and steam sit on transparency,
/// positioned with the exact same transform as ``renderIcon`` so they line up.
func renderLayer(_ layer: IconLayer, pixels: CGFloat, dark: Bool) -> Data {
    let px = Int(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.restoreGraphicsState() }

    let palette = dark ? darkPalette : lightPalette

    if layer == .background {
        // Full bleed: Icon Composer masks to the rounded-rect and adds the glass,
        // so no inset/squircle here.
        NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)!
            .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), angle: -90)
    } else {
        let ctx = gc.cgContext
        ctx.saveGState()
        let scale = pixels * 0.80 / 64
        let offset = (pixels - 64 * scale) / 2
        ctx.translateBy(x: offset, y: pixels - offset)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        if layer == .cup {
            ctx.setFillColor(palette.cup.cgColor)
            ctx.addPath(BrandMark.cup()); ctx.fillPath()
            ctx.setFillColor(palette.crema.cgColor)
            ctx.addPath(BrandMark.crema()); ctx.fillPath()
            ctx.setStrokeColor(palette.cup.cgColor)
            ctx.setLineWidth(3.4); ctx.addPath(BrandMark.handle()); ctx.strokePath()
            ctx.setLineWidth(3.6); ctx.addPath(BrandMark.saucer()); ctx.strokePath()
        } else { // steam
            ctx.setStrokeColor(palette.steam.cgColor)
            ctx.setLineWidth(3.2)
            for wisp in BrandMark.steamWisps() { ctx.addPath(wisp); ctx.strokePath() }
        }
        ctx.restoreGState()
    }

    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

// (size in points, scale) entries for a macOS app icon.
let specs: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

var images: [[String: Any]] = []
var written = Set<String>()

/// Render `icon_<px>.png` (light) and `icon_<px>_dark.png` (dark) once each.
func writePNG(pixels: Int, dark: Bool) -> String {
    let filename = dark ? "icon_\(pixels)_dark.png" : "icon_\(pixels).png"
    if !written.contains(filename) {
        let data = renderIcon(pixels: CGFloat(pixels), dark: dark)
        try! data.write(to: outDir.appendingPathComponent(filename))
        written.insert(filename)
    }
    return filename
}

for spec in specs {
    let pixels = spec.pt * spec.scale
    // Light / any-appearance entry.
    images.append([
        "size": "\(spec.pt)x\(spec.pt)",
        "idiom": "mac",
        "filename": writePNG(pixels: pixels, dark: false),
        "scale": "\(spec.scale)x",
    ])
    // Dark-appearance entry, so macOS uses our artwork in dark icon mode
    // instead of auto-darkening the light icon.
    images.append([
        "size": "\(spec.pt)x\(spec.pt)",
        "idiom": "mac",
        "filename": writePNG(pixels: pixels, dark: true),
        "scale": "\(spec.scale)x",
        "appearances": [["appearance": "luminosity", "value": "dark"]],
    ])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "keepresso make-icon.swift"],
]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))

print("Wrote \(written.count) PNGs + Contents.json to \(outDir.path)")

// Liquid Glass source layers (Icon Composer inputs): the mark split into
// stackable layers at 1024 px, light and dark, so Icon Composer can apply the
// glass material per layer and generate the light/dark/tinted/clear appearances
// for a modern macOS 26 icon. These are build-time sources, not shipped assets.
let layersDir = root.appendingPathComponent("docs/assets/icon-layers")
try? FileManager.default.createDirectory(at: layersDir, withIntermediateDirectories: true)
var layerFiles = 0
for layer in [IconLayer.background, .cup, .steam] {
    for (name, dark) in [("light", false), ("dark", true)] {
        let data = renderLayer(layer, pixels: 1024, dark: dark)
        try! data.write(to: layersDir.appendingPathComponent("\(layer.rawValue)-\(name).png"))
        layerFiles += 1
    }
}
print("Wrote \(layerFiles) Liquid Glass source layers to \(layersDir.path)")
