import AppKit

// Renders the runtime-drawn AppIcon into a full macOS .iconset, then leaves it
// to `iconutil` (in build-app.sh) to pack into Sonar.icns. Compiled together
// with ../Sources/Sonar/AppIcon.swift so there's a single source of truth for
// the artwork — change the icon there and it flows into the bundle icon too.

let iconset = "Sonar.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let image = AppIcon.make()

func writePNG(pixels: Int, name: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

// Standard Apple iconset sizes (point size + @1x/@2x).
for pt in [16, 32, 128, 256, 512] {
    writePNG(pixels: pt, name: "icon_\(pt)x\(pt).png")
    writePNG(pixels: pt * 2, name: "icon_\(pt)x\(pt)@2x.png")
}

print("wrote \(iconset)")
