#!/usr/bin/env swift
// Generates the 8-frame "thinking spark" sprite shown next to a working
// agent session: original artwork, a four-point concave spark that rotates a
// quarter turn per cycle (the shape's own symmetry, so the loop is seamless)
// while its body breathes. Frames are 60x60 black-on-transparent alpha
// masks; the app loads them as template images and tints them at runtime.
//
// Run manually from the repo root when the artwork changes; output is
// checked in:
//   swift tools/generate-spark-frames.swift
// Writes Sources/Keepresso/SparkFrames/spark-0.png ... spark-7.png.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let frameCount = 8
let canvas = 60
let outputDirectory = URL(fileURLWithPath: "Sources/Keepresso/SparkFrames", isDirectory: true)

/// A four-point spark: tips on the axes, sides pulled inward through a
/// low-radius control point midway between tips.
func sparkPath(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, rotation: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
    let start = point(angle: rotation, radius: outerRadius)
    path.move(to: start)
    for tip in 0..<4 {
        let angle = rotation + CGFloat(tip) * .pi / 2
        let nextAngle = rotation + CGFloat(tip + 1) * .pi / 2
        let control = point(angle: angle + .pi / 4, radius: innerRadius)
        path.addQuadCurve(to: point(angle: nextAngle, radius: outerRadius), control: control)
    }
    path.closeSubpath()
    return path
}

func renderFrame(_ index: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: canvas, height: canvas,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let t = CGFloat(index) / CGFloat(frameCount)
    // A quarter turn per cycle matches the 90-degree symmetry, so frame 8
    // lands exactly on frame 0. The body breathes in counter-phase: tips
    // pull in slightly as the waist swells, which reads as a soft morph.
    let rotation = .pi / 2 * t + .pi / 2
    let pulse = sin(2 * .pi * t)
    let outer = CGFloat(canvas) / 2 * (0.84 + 0.06 * pulse)
    let inner = outer * (0.22 - 0.04 * pulse)

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.addPath(sparkPath(
        center: CGPoint(x: CGFloat(canvas) / 2, y: CGFloat(canvas) / 2),
        outerRadius: outer, innerRadius: inner, rotation: rotation))
    context.fillPath()
    return context.makeImage()
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for index in 0..<frameCount {
    guard let image = renderFrame(index) else {
        FileHandle.standardError.write(Data("could not render frame \(index)\n".utf8))
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("spark-\(index).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        FileHandle.standardError.write(Data("could not open \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
    print("wrote \(url.path)")
}
