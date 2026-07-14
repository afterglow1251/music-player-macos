import SwiftUI

/// "00:34"-style clock readout used by the seek bars and time labels.
func clockTimeString(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// The position bar, drawn as the track's real waveform. Observes the clock for
/// the live position and the waveform store for the peaks; scrub/hover state is
/// bound back to the parent. Isolated so ticking doesn't re-render the rest of the
/// window. Click/drag anywhere to seek; the played portion is drawn in accent.
///
/// Shared between the main window's seek bar and the menu-bar mini player —
/// geometry and the unplayed-bar colour are parameters so each host can size it
/// (and keep it legible on its own background: the main window is always dark,
/// the panel's `.menu` material follows the system appearance).
struct WaveformSeekBar: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var waveforms: WaveformStore
    let engine: AudioEngine
    let accent: Color
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    @Binding var seekHoverX: CGFloat?

    /// Column geometry — a thin bar with a hair of gap, SoundCloud-style.
    var barWidth: CGFloat = 2
    var barGap: CGFloat = 1
    var height: CGFloat = 30
    /// The unplayed portion's colour.
    var muted: Color = .white.opacity(0.22)

    /// A floor so silent stretches still show a sliver, not a gap.
    private let minBarFraction: CGFloat = 0.08

    /// Prebuilt bar geometry, rebuilt only when the waveform/size changes — never
    /// on a playback tick. See `barsPath`.
    @State private var cache = BarsCache()

    /// Debounces scroll-driven seeks; see `ScrollSeekDebounce`.
    @State private var scrollSeek = ScrollSeekDebounce()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = clock.duration
            let position = isScrubbing ? scrubTime : clock.currentTime
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0

            Canvas { context, size in
                // Static bars, built once per (waveform, size). Per tick only the
                // progress clip moves: fill the whole waveform muted, then repaint
                // the played span in accent through a clip rect. Two fills, no
                // per-tick path building — the 10 Hz redraw stays nearly free.
                let bars = barsPath(size: size)
                context.fill(bars, with: .color(muted))
                let playedWidth = CGFloat(progress) * size.width
                if playedWidth > 0 {
                    context.clip(to: Path(CGRect(x: 0, y: 0, width: playedWidth, height: size.height)))
                    context.fill(bars, with: .color(accent))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Hover anywhere to preview the time at that position.
            .overlay {
                if let x = seekHoverX, duration > 0 {
                    let frac = min(max(x / width, 0), 1)
                    TooltipLabel(text: clockTimeString(frac * duration))
                        .position(x: min(max(x, 24), width - 24), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): seekHoverX = point.x
                case .ended: seekHoverX = nil
                }
            }
            // Click or drag anywhere on the waveform to seek. minimumDistance 0 so
            // a plain click (no drag) still lands a seek at that x.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrollSeek.cancel()   // the drag owns the scrub now
                        isScrubbing = true
                        scrubTime = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let target = min(max(value.location.x / width, 0), 1) * duration
                        engine.seek(to: target)
                        isScrubbing = false
                    }
            )
            // Scroll over the bar to seek ±~3s per detent. Each event only moves
            // the scrub position; the one real seek commits once the gesture goes
            // quiet — see `ScrollSeekDebounce` for why.
            .scrollToAdjust { units in
                guard duration > 0 else { return }
                let base = isScrubbing ? scrubTime : clock.currentTime
                scrubTime = min(max(base + units * 3, 0), duration)
                isScrubbing = true
                scrollSeek.schedule {
                    engine.seek(to: scrubTime)
                    isScrubbing = false
                }
            }
        }
        .frame(height: height)
    }

    /// The full mirrored-bar shape (both played and unplayed drawn in one colour by
    /// the caller). Rebuilt only when the waveform version or the canvas size
    /// changes; otherwise the cached `Path` is returned untouched, so a playback
    /// tick draws without allocating or looping. With no waveform yet (still
    /// generating, or unreadable) the bars fall to the `minBarFraction` floor, so
    /// the bar always reads as an intentional flat row rather than emptiness.
    ///
    /// Mutating the `@State` cache here is deliberate memoization: `BarsCache` is a
    /// plain reference type (nothing `@Published`), so updating its fields does not
    /// invalidate the view — it just remembers work across redraws.
    private func barsPath(size: CGSize) -> Path {
        let columns = max(1, Int(size.width / (barWidth + barGap)))
        if cache.matches(version: waveforms.version, columns: columns, height: size.height) {
            return cache.path
        }
        let peaks = resample(waveforms.waveform?.peaks ?? [], to: columns)
        let midY = size.height / 2
        var path = Path()
        for i in 0..<columns {
            let peak = peaks.isEmpty ? 0 : CGFloat(peaks[i])
            let barHeight = max(minBarFraction, peak) * (size.height - 2)
            let x = CGFloat(i) * (barWidth + barGap)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        cache.store(path, version: waveforms.version, columns: columns, height: size.height)
        return path
    }

    /// Reduce `peaks` to exactly `count` columns by taking the max over each
    /// column's source range (so transients survive downsampling). Returns the
    /// input unchanged when it already matches, or empty when there's no data.
    private func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard !peaks.isEmpty, count > 0 else { return [] }
        guard peaks.count != count else { return peaks }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = i * peaks.count / count
            let end = max(start + 1, (i + 1) * peaks.count / count)
            var maxV: Float = 0
            for j in start..<min(end, peaks.count) { maxV = max(maxV, peaks[j]) }
            out[i] = maxV
        }
        return out
    }
}

/// Memoizes the seek bar's prebuilt bar `Path` so it's rebuilt only when the
/// waveform (by version) or the canvas geometry changes — not on every playback
/// tick. A reference type held in `@State` so the value persists across the view's
/// redraws.
private final class BarsCache {
    private(set) var path = Path()
    private var version = -1
    private var columns = -1
    private var height: CGFloat = -1

    func matches(version: Int, columns: Int, height: CGFloat) -> Bool {
        self.version == version && self.columns == columns && self.height == height
    }

    func store(_ path: Path, version: Int, columns: Int, height: CGFloat) {
        self.path = path
        self.version = version
        self.columns = columns
        self.height = height
    }
}

/// The "00:34 / 03:12" readout. Observes the clock so only this label — not the
/// whole window — re-renders as the position ticks.
struct SeekTimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let isScrubbing: Bool
    let scrubTime: TimeInterval
    let accent: Color

    var body: some View {
        Text(clockTimeString(isScrubbing ? scrubTime : clock.currentTime)
             + " / " + clockTimeString(clock.duration))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .fixedSize()
    }
}
