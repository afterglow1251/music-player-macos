import AppKit
import CoreText

/// Draws the app's Dock icon at runtime — a dark rounded square with a bold
/// gradient-filled "S" monogram, softly glowing in the app's accent green.
///
/// A bare SwiftPM binary has no bundle/AppIcon asset, so we set this image on
/// `NSApp.applicationIconImage` at launch instead.
enum AppIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { fullRect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rgb = CGColorSpaceCreateDeviceRGB()
            let accent = NSColor(red: 0.29, green: 0.87, blue: 0.42, alpha: 1)

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

            // Soft radial glow behind the letter, for depth.
            let glow = CGGradient(colorsSpace: rgb,
                                  colors: [accent.withAlphaComponent(0.30).cgColor,
                                           accent.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                                   endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.55,
                                   options: [])
            ctx.restoreGState()

            // The "S" monogram — heavy rounded system font, matching the
            // rounded-numeral look used throughout the UI.
            var font = NSFont.systemFont(ofSize: rect.width * 0.62, weight: .heavy)
            if let rounded = font.fontDescriptor.withDesign(.rounded) {
                font = NSFont(descriptor: rounded, size: rect.width * 0.62) ?? font
            }

            // Center on the glyph's actual ink bounds, not font line metrics —
            // line metrics reserve descender space "S" never uses, which would
            // otherwise push it above true center.
            let ctFont = font as CTFont
            var glyph = CGGlyph(0)
            var uniChar: UniChar = 0x53 // "S"
            CTFontGetGlyphsForCharacters(ctFont, &uniChar, &glyph, 1)
            guard let glyphPath = CTFontCreatePathForGlyph(ctFont, glyph, nil) else { return true }
            let bbox = glyphPath.boundingBoxOfPath
            var transform = CGAffineTransform(translationX: rect.midX - bbox.midX,
                                              y: rect.midY - bbox.midY)
            guard let centeredPath = glyphPath.copy(using: &transform) else { return true }

            // Blurred glow pass underneath, in solid accent green.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: rect.width * 0.06, color: accent.withAlphaComponent(0.7).cgColor)
            ctx.setFillColor(accent.cgColor)
            ctx.addPath(centeredPath)
            ctx.fillPath()
            ctx.restoreGState()

            // Crisp top pass, filled with a bright-to-deep green gradient by
            // clipping to the exact glyph outline and drawing the gradient
            // through it.
            ctx.saveGState()
            ctx.addPath(centeredPath)
            ctx.clip()
            let letterGrad = CGGradient(colorsSpace: rgb,
                                        colors: [NSColor(red: 0.66, green: 1.0, blue: 0.70, alpha: 1).cgColor,
                                                 NSColor(red: 0.16, green: 0.72, blue: 0.32, alpha: 1).cgColor] as CFArray,
                                        locations: [0, 1])!
            ctx.drawLinearGradient(letterGrad,
                                   start: CGPoint(x: 0, y: rect.maxY),
                                   end: CGPoint(x: 0, y: rect.minY), options: [])
            ctx.restoreGState()

            return true
        }
    }
}
