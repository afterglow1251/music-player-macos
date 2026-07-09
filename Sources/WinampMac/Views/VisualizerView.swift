import SwiftUI

enum VisualizerMode {
    case spectrum
    case oscilloscope
}

/// The Winamp-style visualization: stacked colored tiles with falling peaks.
///
/// Everything is drawn on an integer pixel grid at a fixed logical resolution,
/// then scaled up — that keeps the chunky, "one tile at a time" retro look
/// instead of smooth modern bars.
struct VisualizerView: View {
    @ObservedObject var engine: AudioEngine
    @Binding var mode: VisualizerMode

    /// Logical (pre-scale) tile grid — mirrors Winamp's tiny vis window.
    private let rows = 16            // vertical tile levels
    private let tileGap: CGFloat = 1 // 1px gap => the "tiles" look

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let bg = WinampPalette.background
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))

                switch mode {
                case .spectrum:
                    drawSpectrum(context: context, size: size, at: timeline.date)
                case .oscilloscope:
                    drawOscilloscope(context: context, size: size)
                }
            }
        }
        .background(WinampPalette.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click flips modes, just like the real thing.
            mode = (mode == .spectrum) ? .oscilloscope : .spectrum
        }
    }

    // MARK: Spectrum (the tiles)

    private func drawSpectrum(context: GraphicsContext, size: CGSize, at date: Date) {
        let frame = engine.analyzer.render(at: date.timeIntervalSinceReferenceDate)
        let barCount = frame.bars.count

        let barSlot = size.width / CGFloat(barCount)
        let barWidth = max(1, floor(barSlot) - tileGap)
        let tileHeight = size.height / CGFloat(rows)

        for i in 0..<barCount {
            let x = floor(CGFloat(i) * barSlot)

            // How many tiles are lit for this bar (0...rows).
            let litTiles = Int(round(frame.bars[i] * Float(rows)))
            for tile in 0..<litTiles {
                // tile 0 = bottom row, rows-1 = top row.
                let y = size.height - CGFloat(tile + 1) * tileHeight
                let rect = CGRect(x: x, y: y + tileGap,
                                  width: barWidth,
                                  height: max(1, tileHeight - tileGap))
                context.fill(Path(rect), with: .color(WinampPalette.spectrumColor(row: tile, of: rows)))
            }

            // The falling peak marker (one tile, drawn even above the bar).
            let peakLevel = Int(round(frame.peaks[i] * Float(rows)))
            if peakLevel > 0 {
                let y = size.height - CGFloat(peakLevel) * tileHeight
                let rect = CGRect(x: x, y: y + tileGap,
                                  width: barWidth,
                                  height: max(1, tileHeight - tileGap))
                context.fill(Path(rect), with: .color(WinampPalette.peak))
            }
        }
    }

    // MARK: Oscilloscope (the green wave)

    private func drawOscilloscope(context: GraphicsContext, size: CGSize) {
        let samples = engine.analyzer.waveform()
        guard samples.count > 1 else { return }

        let midY = size.height / 2
        let step = size.width / CGFloat(samples.count - 1)
        let gain = size.height * 0.9

        var path = Path()
        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * step
            let y = midY - CGFloat(sample) * gain / 2
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(WinampPalette.oscilloscope), lineWidth: 1)
    }
}
