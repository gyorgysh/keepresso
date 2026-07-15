import AppKit
import SwiftUI

/// The 8-frame thinking-spark sprite cycled next to a working agent session
/// in the menu. The frames are pre-rendered 60x60 alpha masks (original
/// artwork; regenerate with `swift tools/generate-spark-frames.swift`),
/// loaded as template images so the row's foreground style tints them at
/// runtime in both menu appearances.
enum SparkFrames {
    static let images: [NSImage] = (0..<8).compactMap { index in
        guard let url = Bundle.main.url(forResource: "spark-\(index)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        // Drawn at menu-dot scale; 60px source stays crisp on Retina.
        image.size = NSSize(width: 11, height: 11)
        return image
    }
}

/// Cycles the spark frames. Lives only inside the open menu, and a
/// `TimelineView` ticks only while its view is visible, so the animation
/// costs nothing while the menu is closed.
struct SparkView: View {
    private static let frameInterval: TimeInterval = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.frameInterval)
            Image(nsImage: SparkFrames.images[tick % SparkFrames.images.count])
                .renderingMode(.template)
        }
    }
}
