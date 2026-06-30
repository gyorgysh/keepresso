#!/usr/bin/env swift
//
// make-icon.swift — generate Keepresso's app icon asset catalog.
//
// Renders a clean espresso-cup icon (warm gradient squircle + white
// `cup.and.saucer.fill` SF Symbol) at every size macOS needs, and writes a
// ready-to-use AppIcon.appiconset. Re-run after tweaking the look:
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

/// A white-tinted espresso-cup symbol, rendered in its own transparent layer so
/// the tint only paints the glyph (a `sourceAtop` fill against the opaque icon
/// background would flood the whole rect).
func whiteCup(pointSize: CGFloat) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    symbol.isTemplate = true
    let s = symbol.size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(s.width)), pixelsHigh: Int(ceil(s.height)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = s
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let r = NSRect(origin: .zero, size: s)
    symbol.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop) // here the only opaque pixels are the glyph itself
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: s)
    image.addRepresentation(rep)
    return image
}

/// Draw the icon at a given pixel size straight into a bitmap (no `lockFocus`,
/// which is unreliable when run headless) and return PNG data. `dark` selects a
/// deeper gradient for the dark-appearance variant so macOS uses our artwork
/// instead of auto-darkening the light icon into a near-black square.
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

    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)

    // macOS icons leave a transparent margin around a continuous-corner squircle.
    let inset = pixels * 0.085
    let body = canvas.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // gyorgy.sh periwinkle (#5B5BD6), as a subtle vertical gradient. The dark
    // variant uses a deeper indigo so it reads well on a dark icon backdrop.
    let top: NSColor
    let bottom: NSColor
    if dark {
        top = NSColor(calibratedRed: 0.27, green: 0.27, blue: 0.55, alpha: 1)    // ~#454590
        bottom = NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.36, alpha: 1) // ~#29295C
    } else {
        top = NSColor(calibratedRed: 0.42, green: 0.42, blue: 0.89, alpha: 1)
        bottom = NSColor(calibratedRed: 0.31, green: 0.31, blue: 0.79, alpha: 1)
    }
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // White espresso cup, centered.
    if let glyph = whiteCup(pointSize: pixels * 0.46) {
        let s = glyph.size
        let rect = NSRect(
            x: (pixels - s.width) / 2,
            y: (pixels - s.height) / 2,
            width: s.width,
            height: s.height
        )
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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
