import CoreGraphics

/// The Pervigil mark's geometry: a solid block with a notch cut into its left
/// edge and a play triangle cut out of it, in the brand's 562 x 650 viewBox
/// (y pointing down). The source of truth is
/// `docs/assets/brand/pervigil-mark.svg`:
///
///     M0 0H562V650H0V231H190L0 124Z  M190 231 557 438 190 645Z
///
/// The two subpaths are filled with the even-odd rule, so the triangle reads
/// as a hole. The notch's diagonal and the triangle's top edge are one line,
/// and the left bar is 190 units wide.
///
/// Geometry only (CoreGraphics, no UI imports) because every rendering shares
/// it: ``MenuBarIcon`` rasterizes a template `NSImage` for the menu bar,
/// ``BrandMarkGlyph`` draws it in real windows, the widget extension draws
/// the desktop-widget badge, and `scripts/make-symbol.swift` exports the
/// custom SF Symbol for the Control Center toggle. The file is compiled into
/// both the app and widget targets (see `project.yml`).
enum BrandMark {
    /// The viewBox the paths below are defined in.
    static let viewBox = CGRect(x: 0, y: 0, width: 562, height: 650)

    /// Width over height, for sizing frames to the mark.
    static let aspectRatio: CGFloat = viewBox.width / viewBox.height

    /// The block with the notch cut into its left edge.
    static func silhouette() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 562, y: 0))
        p.addLine(to: CGPoint(x: 562, y: 650))
        p.addLine(to: CGPoint(x: 0, y: 650))
        p.addLine(to: CGPoint(x: 0, y: 231))
        p.addLine(to: CGPoint(x: 190, y: 231))
        p.addLine(to: CGPoint(x: 0, y: 124))
        p.closeSubpath()
        return p
    }

    /// The play triangle cut out of the block.
    static func playCut() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 190, y: 231))
        p.addLine(to: CGPoint(x: 557, y: 438))
        p.addLine(to: CGPoint(x: 190, y: 645))
        p.closeSubpath()
        return p
    }

    /// The whole mark in viewBox units. Fill it with the even-odd rule.
    static func path() -> CGPath {
        let p = CGMutablePath()
        p.addPath(silhouette())
        p.addPath(playCut())
        return p
    }

    /// Scales and centers the viewBox into `rect`, preserving the aspect ratio.
    static func transform(fitting rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.midX - viewBox.midX * scale
        let dy = rect.midY - viewBox.midY * scale
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// The mark fitted into `rect`. Fill it with the even-odd rule.
    static func path(fitting rect: CGRect) -> CGPath {
        var t = transform(fitting: rect)
        return path().copy(using: &t) ?? path()
    }

    /// The share of the mark's height, from the bottom, that the low-battery
    /// pause fills in the system's low-power yellow: the last of the charge.
    static let lowBatteryLevel: CGFloat = 0.24
}
