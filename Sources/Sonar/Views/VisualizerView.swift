import SwiftUI
import Foundation

enum VisualizerMode: CaseIterable {
    case spectrum
    case oscilloscope
    case bloom       // MilkDrop-style reactive kaleidoscope

    /// Next mode in the cycle — double-clicking the visualizer steps through these.
    var next: VisualizerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
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
    /// Transparent background so the tiles blend onto whatever's behind them
    /// (a blurred cover in fullscreen) instead of a hard black box.
    var transparentBackground: Bool = false

    private let tileGap: CGFloat = 1 // 1px gap => the "tiles" look

    var body: some View {
        // Cap at ~30fps, and stop entirely when paused — no need to burn CPU
        // animating a still visualization.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !engine.isPlaying)) { timeline in
            Canvas { context, size in
                if !transparentBackground {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.background))
                }

                switch mode {
                case .spectrum:
                    drawSpectrum(context: context, size: size, at: timeline.date)
                case .oscilloscope:
                    drawOscilloscope(context: context, size: size)
                case .bloom:
                    drawBloom(context: context, size: size, at: timeline.date)
                }
            }
        }
        .background(transparentBackground ? Color.clear : Palette.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click steps through the modes, just like the real thing.
            mode = mode.next
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

    // MARK: Bloom (MilkDrop-style reactive kaleidoscope)

    /// A hypnotic, symmetric, audio-reactive scene built from the same FFT the tiles
    /// use — a radial "flower" of spectrum spokes (mirrored for symmetry), the
    /// oscilloscope wrapped into a pulsing ring, bass-driven rings blooming outward,
    /// and a glowing core. Everything is derived from time + audio, so it stays
    /// stateless and cheap. Not a MilkDrop engine — a MilkDrop *feel*.
    private func drawBloom(context: GraphicsContext, size: CGSize, at date: Date) {
        let bars = engine.analyzer.render(at: date.timeIntervalSinceReferenceDate).bars
        guard bars.count > 1 else { return }

        let time = date.timeIntervalSinceReferenceDate
        let bass = CGFloat(min(max(engine.analyzer.bassLevel, 0), 1))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) / 2
        let spin = time * 0.15

        // 1. Symmetric spectrum spokes — mirror the bars so the flower is balanced.
        let petals = bars + bars.reversed()
        let innerR = maxR * (0.16 + bass * 0.06)
        for (i, value) in petals.enumerated() {
            let level = CGFloat(value)
            let angle = spin + Double(i) / Double(petals.count) * 2 * .pi
            var spoke = Path()
            spoke.move(to: point(center, angle, innerR))
            spoke.addLine(to: point(center, angle, innerR + level * (maxR - innerR)))
            let row = min(max(Int(level * CGFloat(rows - 1)), 0), rows - 1)
            context.stroke(spoke, with: .color(theme.spectrumColor(row: row, of: rows).opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // 2. Oscilloscope wrapped into a ring — the flowing line that reads as MilkDrop.
        let wave = engine.analyzer.waveform()
        if wave.count > 2 {
            let ringR = maxR * (0.52 + bass * 0.08)
            let amp = maxR * 0.16
            var ring = Path()
            for (i, sample) in wave.enumerated() {
                let angle = -spin * 1.3 + Double(i) / Double(wave.count) * 2 * .pi
                let p = point(center, angle, ringR + CGFloat(sample) * amp)
                if i == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
            }
            ring.closeSubpath()
            context.stroke(ring, with: .color(theme.oscilloscope.opacity(0.85)), lineWidth: 1.5)
        }

        // 3. Bass rings blooming outward — phase from time, so no per-frame state.
        let ringCount = 3
        for r in 0..<ringCount {
            let phase = (time * 0.25 + Double(r) / Double(ringCount)).truncatingRemainder(dividingBy: 1)
            let radius = CGFloat(phase) * maxR
            let fade = (1 - CGFloat(phase)) * (0.2 + bass * 0.5)
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
            context.stroke(circle, with: .color(theme.peak.opacity(fade)), lineWidth: 1 + bass * 2)
        }

        // 4. Pulsing core with a soft glow halo.
        let coreR = maxR * (0.05 + bass * 0.12)
        context.fill(disc(center, coreR * 2.4), with: .color(theme.peak.opacity(0.15)))
        context.fill(disc(center, coreR), with: .color(theme.peak.opacity(0.85)))
    }

    /// A point on the circle of radius `r` at `angle`, centered on `c`.
    private func point(_ c: CGPoint, _ angle: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: c.x + CGFloat(cos(angle)) * r, y: c.y + CGFloat(sin(angle)) * r)
    }

    private func disc(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}
