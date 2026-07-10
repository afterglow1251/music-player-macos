import SwiftUI

enum VisualizerMode {
    case spectrum
    case oscilloscope
}

/// The classic tile visualization: stacked colored tiles with falling peaks.
///
/// Everything is drawn on an integer pixel grid at a fixed logical resolution,
/// then scaled up — that keeps the chunky, "one tile at a time" retro look
/// instead of smooth modern bars.
struct VisualizerView: View {
    @ObservedObject var engine: AudioEngine
    @Binding var mode: VisualizerMode
    var theme: VisualizerTheme = .classic
    /// Number of vertical tile levels. Higher = a finer grid (fullscreen uses more).
    var rows: Int = 16
    /// Horizontal upsample factor: linearly interpolate the analyzer's bars into
    /// `count * columnScale` columns, so a wide (fullscreen) layout doesn't stretch
    /// the handful of bars into grotesquely wide blocks. 1 = raw bars (small window).
    var columnScale: Int = 1

    private let tileGap: CGFloat = 1 // 1px gap => the "tiles" look

    var body: some View {
        // Cap at ~30fps, and stop entirely when paused — no need to burn CPU
        // animating a still visualization.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !engine.isPlaying)) { timeline in
            Canvas { context, size in
                let bg = Palette.background
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))

                switch mode {
                case .spectrum:
                    drawSpectrum(context: context, size: size, at: timeline.date)
                case .oscilloscope:
                    drawOscilloscope(context: context, size: size)
                }
            }
        }
        .background(Palette.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click flips modes, just like the real thing.
            mode = (mode == .spectrum) ? .oscilloscope : .spectrum
        }
    }

    // MARK: Spectrum (the tiles)

    private func drawSpectrum(context: GraphicsContext, size: CGSize, at date: Date) {
        let frame = engine.analyzer.render(at: date.timeIntervalSinceReferenceDate)
        let bars = columnScale > 1 ? Self.upsample(frame.bars, factor: columnScale) : frame.bars
        let peaks = columnScale > 1 ? Self.upsample(frame.peaks, factor: columnScale) : frame.peaks
        let barCount = bars.count

        let barSlot = size.width / CGFloat(barCount)
        let barWidth = max(1, floor(barSlot) - tileGap)
        let tileHeight = size.height / CGFloat(rows)

        for i in 0..<barCount {
            let x = floor(CGFloat(i) * barSlot)

            // How many tiles are lit for this bar (0...rows).
            let litTiles = Int(round(bars[i] * Float(rows)))
            for tile in 0..<litTiles {
                // tile 0 = bottom row, rows-1 = top row.
                let y = size.height - CGFloat(tile + 1) * tileHeight
                let rect = CGRect(x: x, y: y + tileGap,
                                  width: barWidth,
                                  height: max(1, tileHeight - tileGap))
                context.fill(Path(rect), with: .color(theme.spectrumColor(row: tile, of: rows)))
            }

            // The falling peak marker (one tile, drawn even above the bar).
            let peakLevel = Int(round(peaks[i] * Float(rows)))
            if peakLevel > 0 {
                let y = size.height - CGFloat(peakLevel) * tileHeight
                let rect = CGRect(x: x, y: y + tileGap,
                                  width: barWidth,
                                  height: max(1, tileHeight - tileGap))
                context.fill(Path(rect), with: .color(theme.peak))
            }
        }
    }

    /// Linearly interpolate `values` into `values.count * factor` samples, so the
    /// tile columns stay a sane width on a wide display.
    private static func upsample(_ values: [Float], factor: Int) -> [Float] {
        guard factor > 1, values.count > 1 else { return values }
        var out = [Float]()
        out.reserveCapacity(values.count * factor)
        for i in 0..<values.count {
            let a = values[i]
            let b = values[min(i + 1, values.count - 1)]
            for j in 0..<factor {
                let t = Float(j) / Float(factor)
                out.append(a + (b - a) * t)
            }
        }
        return out
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
        context.stroke(path, with: .color(theme.oscilloscope), lineWidth: 1)
    }
}
