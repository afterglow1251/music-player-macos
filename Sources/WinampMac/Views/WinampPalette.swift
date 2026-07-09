import SwiftUI

/// Classic Winamp visualization colors, adapted from the default (base) skin's
/// VISCOLOR.TXT. The spectrum gradient runs green (bottom) → yellow → red (top).
///
/// These are the 16 analyzer colors, ordered **bottom row → top row**. Swapping
/// this array is all it takes to reskin the visualizer later.
enum WinampPalette {

    static let background = Color(red: 0, green: 0, blue: 0)

    /// Peak marker — a light, slightly warm gray, like the classic skin.
    static let peak = Color(red: 0.72, green: 0.75, blue: 0.78)

    /// Oscilloscope line — Winamp's signature bright green.
    static let oscilloscope = Color(red: 0.14, green: 0.87, blue: 0.24)

    /// 16 spectrum colors, bottom (index 0) → top (index 15).
    private static let spectrum: [Color] = [
        rgb(0,   208, 0),    // bottom: bright green
        rgb(0,   208, 0),
        rgb(48,  208, 0),
        rgb(104, 208, 0),
        rgb(152, 208, 0),
        rgb(192, 208, 0),
        rgb(216, 208, 0),    // yellow-green
        rgb(232, 208, 0),
        rgb(240, 200, 0),    // yellow
        rgb(240, 176, 0),
        rgb(240, 148, 0),
        rgb(240, 120, 0),    // orange
        rgb(240, 92,  0),
        rgb(240, 64,  0),
        rgb(240, 40,  0),    // red-orange
        rgb(240, 16,  0),    // top: red
    ]

    /// Color for tile `row` (0 = bottom) of a bar `total` rows tall.
    static func spectrumColor(row: Int, of total: Int) -> Color {
        guard total > 1 else { return spectrum[0] }
        // Map the bar's row count onto the 16-color palette.
        let idx = Int(round(Double(row) / Double(total - 1) * Double(spectrum.count - 1)))
        return spectrum[min(max(idx, 0), spectrum.count - 1)]
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}
