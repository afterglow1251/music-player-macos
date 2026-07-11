import AppKit

/// Draws the app's Dock icon at runtime — a black squircle holding a bold
/// accent-green play triangle. The black tone is sampled to match the
/// reference icon.
///
/// A bare SwiftPM binary has no bundle/AppIcon asset, so we set this image on
/// `NSApp.applicationIconImage` at launch instead.
enum AppIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { fullRect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rgb = CGColorSpaceCreateDeviceRGB()

            // The app's accent green (Theme.accent).
            let accent = NSColor(red: 0.29, green: 0.87, blue: 0.42, alpha: 1)

            // macOS icons leave ~8.5% transparent padding around the shape.
            let rect = fullRect.insetBy(dx: fullRect.width * 0.085, dy: fullRect.height * 0.085)
            let shape = squircle(in: rect)
            let c = CGPoint(x: rect.midX, y: rect.midY)

            // Black background — dark gradient sampled from the reference icon
            // (~rgb(40,40,43) top → rgb(16,16,18) bottom).
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip()
            let bg = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(red: 0.157, green: 0.157, blue: 0.169, alpha: 1).cgColor,
                                         NSColor(red: 0.063, green: 0.063, blue: 0.071, alpha: 1).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawLinearGradient(bg,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])

            // Subtle top specular highlight on the black.
            let hlC = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.20)
            let hl = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(calibratedWhite: 1, alpha: 0.10).cgColor,
                                         NSColor(calibratedWhite: 1, alpha: 0).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawRadialGradient(hl, startCenter: hlC, startRadius: 0,
                                   endCenter: hlC, endRadius: rect.width * 0.40, options: [])
            ctx.restoreGState()

            // Bold play triangle, optically centered (nudged left of the frame
            // center so its visual mass sits centered).
            let tw = rect.width * 0.34
            let th = tw * 1.18
            let px = c.x - tw * 0.42
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: px, y: c.y - th / 2))
            tri.addLine(to: CGPoint(x: px, y: c.y + th / 2))
            tri.addLine(to: CGPoint(x: px + tw, y: c.y))
            tri.closeSubpath()

            // Glow + solid base.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: rect.width * 0.055, color: accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(rect.width * 0.05)
            ctx.addPath(tri); ctx.setStrokeColor(accent.cgColor); ctx.strokePath()
            ctx.addPath(tri); ctx.setFillColor(accent.cgColor); ctx.fillPath()
            ctx.restoreGState()

            // Fresh vertical gradient over the triangle (brighter at the top).
            ctx.saveGState()
            ctx.addPath(tri); ctx.clip()
            let triGrad = CGGradient(colorsSpace: rgb,
                                     colors: [NSColor(red: 0.55, green: 1.0, blue: 0.6, alpha: 1).cgColor,
                                              accent.cgColor] as CFArray,
                                     locations: [0, 1])!
            ctx.drawLinearGradient(triGrad,
                                   start: CGPoint(x: 0, y: c.y + th / 2),
                                   end: CGPoint(x: 0, y: c.y - th / 2), options: [])
            ctx.restoreGState()

            return true
        }
    }

    /// Continuous "squircle" (superellipse) path — iOS-style rounded corners.
    private static func squircle(in rect: NSRect, n: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX, cy = rect.midY
        let a = rect.width / 2, b = rect.height / 2
        let steps = 300
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let px = cx + a * copysign(pow(abs(ct), 2 / n), ct)
            let py = cy + b * copysign(pow(abs(st), 2 / n), st)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        return path
    }
}
