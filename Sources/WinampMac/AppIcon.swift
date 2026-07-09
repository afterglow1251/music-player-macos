import AppKit

/// Draws the app's Dock icon at runtime — a dark rounded square with green
/// equalizer bars and white peak caps, echoing the in-app visualizer.
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

            // Equalizer bars.
            let heights: [CGFloat] = [0.42, 0.72, 1.0, 0.60, 0.50]
            let barCount = heights.count
            let areaW = rect.width * 0.60
            let areaH = rect.height * 0.46
            let originX = rect.minX + (rect.width - areaW) / 2
            let baseY = rect.minY + rect.height * 0.27
            let gap = areaW * 0.055
            let barW = (areaW - gap * CGFloat(barCount - 1)) / CGFloat(barCount)

            let green = NSColor(red: 0.20, green: 0.80, blue: 0.35, alpha: 1).cgColor
            let greenBright = NSColor(red: 0.55, green: 1.0, blue: 0.55, alpha: 1).cgColor

            for i in 0..<barCount {
                let h = areaH * heights[i]
                let x = originX + CGFloat(i) * (barW + gap)

                let bar = NSBezierPath(roundedRect: CGRect(x: x, y: baseY, width: barW, height: h),
                                       xRadius: barW * 0.32, yRadius: barW * 0.32)
                ctx.saveGState()
                bar.addClip()
                let grad = CGGradient(colorsSpace: rgb, colors: [green, greenBright] as CFArray,
                                      locations: [0, 1])!
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: baseY),
                                       end: CGPoint(x: 0, y: baseY + h), options: [])
                ctx.restoreGState()

                // White peak cap floating above the bar.
                let capH = barW * 0.26
                let capRect = CGRect(x: x, y: baseY + h + gap * 0.9, width: barW, height: capH)
                let cap = NSBezierPath(roundedRect: capRect, xRadius: capH / 2, yRadius: capH / 2)
                NSColor(calibratedWhite: 0.92, alpha: 0.95).setFill()
                cap.fill()
            }
            return true
        }
    }
}
