import AppKit

/// Draws the app's Dock icon at runtime — a dark rounded square with green
/// concentric "sonar" rings and a bright center blip.
///
/// A bare SwiftPM binary has no bundle/AppIcon asset, so we set this image on
/// `NSApp.applicationIconImage` at launch instead.
enum AppIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { fullRect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rgb = CGColorSpaceCreateDeviceRGB()

            // macOS icons leave ~10% transparent padding around the rounded
            // square, so draw everything inside an inset content rect.
            let rect = fullRect.insetBy(dx: fullRect.width * 0.10, dy: fullRect.height * 0.10)

            // Background: rounded square with a subtle dark gradient.
            let bg = NSBezierPath(roundedRect: rect,
                                  xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
            ctx.saveGState()
            bg.addClip()
            let bgGrad = CGGradient(colorsSpace: rgb,
                                    colors: [NSColor(calibratedWhite: 0.13, alpha: 1).cgColor,
                                             NSColor(calibratedWhite: 0.03, alpha: 1).cgColor] as CFArray,
                                    locations: [0, 1])!
            ctx.drawLinearGradient(bgGrad,
                                   start: CGPoint(x: 0, y: rect.maxY),
                                   end: CGPoint(x: 0, y: rect.minY), options: [])
            ctx.restoreGState()

            // Concentric sonar rings emanating from the center.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let green = NSColor(red: 0.29, green: 0.87, blue: 0.42, alpha: 1)
            let rings: [(radius: CGFloat, alpha: CGFloat, width: CGFloat)] = [
                (0.15, 1.00, 0.045),
                (0.25, 0.75, 0.038),
                (0.35, 0.50, 0.030),
                (0.44, 0.28, 0.024),
            ]
            for ring in rings {
                let r = rect.width * ring.radius
                let circle = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r,
                                                         width: r * 2, height: r * 2))
                circle.lineWidth = rect.width * ring.width
                green.withAlphaComponent(ring.alpha).setStroke()
                circle.stroke()
            }

            // Bright center blip.
            let blipR = rect.width * 0.06
            let blip = NSBezierPath(ovalIn: CGRect(x: center.x - blipR, y: center.y - blipR,
                                                   width: blipR * 2, height: blipR * 2))
            NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1).setFill()
            blip.fill()

            return true
        }
    }
}
