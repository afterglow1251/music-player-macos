import SwiftUI

enum Palette {
    /// The visualizer always sits on black.
    static let background = Color.black
}

/// A color scheme for the spectrum visualizer: the 16-step bar gradient
/// (bottom → top), the peak marker, and the oscilloscope line.
struct VisualizerTheme: Identifiable, Equatable {
    let name: String
    let colors: [Color]
    let peak: Color
    let oscilloscope: Color
    var id: String { name }

    /// Color for tile `row` (0 = bottom) of a bar `total` rows tall.
    func spectrumColor(row: Int, of total: Int) -> Color {
        guard total > 1 else { return colors.first ?? .green }
        let idx = Int(round(Double(row) / Double(total - 1) * Double(colors.count - 1)))
        return colors[min(max(idx, 0), colors.count - 1)]
    }

    static func == (lhs: VisualizerTheme, rhs: VisualizerTheme) -> Bool { lhs.name == rhs.name }

    // MARK: Themes

    static let all: [VisualizerTheme] = [classic, ice, fire, rainbow, mono,
                                         sunset, ocean, magenta, gold, neon]

    static let classic = VisualizerTheme(
        name: "Classic",
        colors: gradient([(0, 208, 0), (216, 208, 0), (240, 120, 0), (240, 16, 0)]),
        peak: Color(white: 0.75),
        oscilloscope: rgb(36, 222, 61))

    static let ice = VisualizerTheme(
        name: "Ice",
        colors: gradient([(0, 110, 255), (0, 200, 255), (130, 230, 255), (235, 250, 255)]),
        peak: .white,
        oscilloscope: rgb(90, 205, 255))

    static let fire = VisualizerTheme(
        name: "Fire",
        colors: gradient([(150, 0, 0), (240, 70, 0), (255, 170, 0), (255, 240, 140)]),
        peak: .white,
        oscilloscope: rgb(255, 140, 0))

    static let rainbow = VisualizerTheme(
        name: "Rainbow",
        colors: gradient([(148, 0, 211), (0, 60, 255), (0, 200, 0), (255, 235, 0), (255, 0, 0)]),
        peak: .white,
        oscilloscope: rgb(200, 120, 255))

    static let mono = VisualizerTheme(
        name: "Mono",
        colors: gradient([(70, 70, 70), (150, 150, 150), (220, 220, 220), (255, 255, 255)]),
        peak: .white,
        oscilloscope: Color(white: 0.85))

    static let sunset = VisualizerTheme(
        name: "Sunset",
        colors: gradient([(255, 70, 120), (255, 120, 80), (255, 190, 60), (255, 240, 160)]),
        peak: .white,
        oscilloscope: rgb(255, 130, 110))

    static let ocean = VisualizerTheme(
        name: "Ocean",
        colors: gradient([(0, 70, 140), (0, 150, 190), (0, 205, 185), (150, 245, 220)]),
        peak: .white,
        oscilloscope: rgb(0, 205, 190))

    static let magenta = VisualizerTheme(
        name: "Magenta",
        colors: gradient([(110, 0, 130), (200, 0, 190), (255, 60, 200), (255, 185, 240)]),
        peak: .white,
        oscilloscope: rgb(255, 80, 220))

    static let gold = VisualizerTheme(
        name: "Gold",
        colors: gradient([(120, 80, 0), (200, 150, 0), (255, 210, 40), (255, 245, 185)]),
        peak: .white,
        oscilloscope: rgb(255, 210, 60))

    static let neon = VisualizerTheme(
        name: "Neon",
        colors: gradient([(255, 0, 140), (200, 0, 255), (0, 180, 255), (0, 255, 220)]),
        peak: .white,
        oscilloscope: rgb(0, 255, 220))

    // MARK: Builders

    private static func gradient(_ stops: [(Double, Double, Double)], count: Int = 16) -> [Color] {
        guard stops.count > 1 else { return stops.map { rgb($0.0, $0.1, $0.2) } }
        var result: [Color] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1) * Double(stops.count - 1)
            let lo = Int(floor(t)), hi = min(lo + 1, stops.count - 1)
            let f = t - Double(lo)
            let a = stops[lo], b = stops[hi]
            result.append(rgb(a.0 + (b.0 - a.0) * f,
                              a.1 + (b.1 - a.1) * f,
                              a.2 + (b.2 - a.2) * f))
        }
        return result
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}
