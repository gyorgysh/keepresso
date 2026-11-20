#!/usr/bin/env swift
//
// make-icon.swift: generate Pervigil's app icon from the brand mark.
//
// The mark (docs/assets/brand/pervigil-mark.svg) is split into stackable
// layers for Apple's Icon Composer (Xcode 26), which assembles them into
// `Sources/Pervigil/AppIcon.icon` with the glass material and the light /
// dark / tinted / clear appearances. The layers are also copied straight into
// the .icon bundle's Assets folder, so a plain re-run keeps it current:
//
//   swift scripts/make-icon.swift
//
// Output:
//   docs/assets/icon-layers/{background,mark}-{light,dark}.png (1024px)
//   Sources/Pervigil/AppIcon.icon/Assets/ (same files)
//   docs/assets/icon.png (512px flattened icon for the README and project
//   pickers that look for an icon.png)
//
import AppKit

// Resolve the repo root from this script's location.
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// One appearance, from the colorways in docs/assets/brand/README.md.
struct IconPalette {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let markTop: NSColor
    let markBottom: NSColor
}

/// "On blue": a white mark on the brand blue.
let lightPalette = IconPalette(
    backgroundTop: srgb(0x69A9ED), backgroundBottom: srgb(0x2D8EF9),
    markTop: srgb(0xFFFFFF), markBottom: srgb(0xFFFFFF)
)

/// "Blue" mark on the dark ground.
let darkPalette = IconPalette(
    backgroundTop: srgb(0x171717), backgroundBottom: srgb(0x010101),
    markTop: srgb(0x6EAFF6), markBottom: srgb(0x007AFF)
)

/// The mark in the SVG's own grid (viewBox 0 0 562 650, y pointing down):
/// a solid block with a notch on the left edge and a play triangle cut out.
enum PervigilMark {
    static let size = CGSize(width: 562, height: 650)

    static func path() -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: 562, y: 0), CGPoint(x: 562, y: 650),
            CGPoint(x: 0, y: 650), CGPoint(x: 0, y: 231), CGPoint(x: 190, y: 231),
            CGPoint(x: 0, y: 124),
        ])
        p.closeSubpath()
        p.addLines(between: [CGPoint(x: 190, y: 231), CGPoint(x: 557, y: 438), CGPoint(x: 190, y: 645)])
        p.closeSubpath()
        return p
    }
}

/// The mark's height as a share of the icon body it sits on.
let markShare: CGFloat = 0.54

/// Fill the mark, fitted to `markShare` of `body` and centered in it, with a
/// top-to-bottom gradient (the brand gradient stops at 80%).
func drawMark(in ctx: CGContext, body: CGRect, palette: IconPalette) {
    let scale = body.height * markShare / PervigilMark.size.height
    let w = PervigilMark.size.width * scale, h = PervigilMark.size.height * scale
    ctx.saveGState()
    // Flip into the SVG's y-down grid.
    ctx.translateBy(x: body.midX - w / 2, y: body.midY + h / 2)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.addPath(PervigilMark.path())
    ctx.clip(using: .evenOdd)
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [palette.markTop.cgColor, palette.markBottom.cgColor] as CFArray,
        locations: [0, 0.8]
    )!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: PervigilMark.size.height),
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawBackground(in rect: NSRect, palette: IconPalette) {
    NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)!
        .draw(in: rect, angle: -90)
}

func render(pixels: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    NSGraphicsContext.current = gc
    draw(gc.cgContext, CGFloat(pixels))
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

enum IconLayer: String { case background, mark }

/// One Icon Composer layer: the background is full bleed (Icon Composer masks
/// the icon shape and adds the glass); the mark sits on transparency.
func renderLayer(_ layer: IconLayer, dark: Bool) -> Data {
    let palette = dark ? darkPalette : lightPalette
    return render(pixels: 1024) { ctx, side in
        let full = NSRect(x: 0, y: 0, width: side, height: side)
        switch layer {
        case .background: drawBackground(in: full, palette: palette)
        case .mark: drawMark(in: ctx, body: full, palette: palette)
        }
    }
}

/// The flattened icon on Apple's macOS grid: an 824pt rounded body inset in a
/// 1024pt canvas, so it lines up with other app icons next to it.
func renderFlattened(pixels: Int) -> Data {
    render(pixels: pixels) { ctx, side in
        let unit = side / 1024
        let body = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawBackground(in: body, palette: lightPalette)
        NSGraphicsContext.restoreGraphicsState()
        drawMark(in: ctx, body: body, palette: lightPalette)
    }
}

let fm = FileManager.default
let layersDir = root.appendingPathComponent("docs/assets/icon-layers")
let iconAssets = root.appendingPathComponent("Sources/Pervigil/AppIcon.icon/Assets")
for dir in [layersDir, iconAssets] {
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
}
var written = 0
for layer in [IconLayer.background, .mark] {
    for (name, dark) in [("light", false), ("dark", true)] {
        let data = renderLayer(layer, dark: dark)
        let file = "\(layer.rawValue)-\(name).png"
        try! data.write(to: layersDir.appendingPathComponent(file))
        try! data.write(to: iconAssets.appendingPathComponent(file))
        written += 1
    }
}
try! renderFlattened(pixels: 512).write(to: root.appendingPathComponent("docs/assets/icon.png"))
print("Wrote \(written) layers to \(layersDir.path) and \(iconAssets.path), plus docs/assets/icon.png")
