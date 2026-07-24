import SwiftUI

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
    /// Chapter markers for the loaded track (empty for the common single-song
    /// case). Drawn as dividers over the waveform; a click near one snaps to it.
    var chapters: [Chapter] = []
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
            // Chapter boundaries: hidden while idle so the waveform reads clean,
            // fading in only while the bar is hovered/scrubbed — enough to aim the
            // magnet at, without permanently cutting the wave into blocks.
            .overlay { chapterDividers(width: width, duration: duration) }
            // Hover anywhere to preview the time at that position.
            .overlay {
                if let x = seekHoverX, duration > 0 {
                    let frac = min(max(x / width, 0), 1)
                    TooltipLabel(text: hoverLabel(at: frac * duration))
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
                        // Snap live, so the playhead visibly magnetizes to a nearby
                        // boundary as you press/drag near it — not just on release.
                        scrubTime = snappedTime(atX: value.location.x, duration: duration, width: width)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        engine.seek(to: snappedTime(atX: value.location.x, duration: duration, width: width))
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

    /// Thin dividers at each chapter boundary, drawn over the waveform but shown
    /// only while the bar is hovered or scrubbed (`seekHoverX != nil`) — a soft
    /// fade in/out. Nothing to draw for an unchaptered track.
    @ViewBuilder
    private func chapterDividers(width: CGFloat, duration: TimeInterval) -> some View {
        if duration > 0, !chapters.isEmpty {
            Canvas { context, size in
                for chapter in chapters {
                    let frac = chapter.start / duration
                    guard frac > 0.003, frac < 0.997 else { continue }
                    let x = CGFloat(frac) * size.width
                    context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                                 with: .color(.white.opacity(0.45)))
                }
            }
            .allowsHitTesting(false)
            .opacity(seekHoverX != nil ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: seekHoverX != nil)
        }
    }

    /// The section covering `time`, if the track has chapters — the last one that
    /// has started by then.
    private func chapter(at time: TimeInterval) -> Chapter? {
        chapters.last { $0.start <= time + 0.001 }
    }

    /// The seek time for a press at horizontal position `x`, magnetized to a
    /// chapter boundary within a comfortable pixel radius — so aiming at a divider
    /// (or landing a touch either side) lands exactly on that section. Pixel-based,
    /// not time-based, so the pull feels the same on a 3-minute song and a 3-hour
    /// mix. No chapter in range → the raw position under the cursor.
    private func snappedTime(atX x: CGFloat, duration: TimeInterval, width: CGFloat) -> TimeInterval {
        let raw = min(max(x / width, 0), 1) * duration
        guard !chapters.isEmpty, width > 0 else { return raw }
        let tolerance: CGFloat = 12
        var nearest: (distance: CGFloat, start: TimeInterval)?
        for chapter in chapters {
            let boundaryX = CGFloat(chapter.start / duration) * width
            let distance = abs(boundaryX - x)
            if distance <= tolerance, nearest == nil || distance < nearest!.distance {
                nearest = (distance, chapter.start)
            }
        }
        return nearest?.start ?? raw
    }

    /// The hover tooltip's text: the time, prefixed with the section name when the
    /// track is chaptered so a mix reads "Song — 12:04" as you scan it.
    private func hoverLabel(at time: TimeInterval) -> String {
        let clock = clockTimeString(time)
        if let title = chapter(at: time)?.title, !title.isEmpty {
            return "\(title)  ·  \(clock)"
        }
        return clock
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

/// The now-playing title line. Shows the track's own title, and — for a chaptered
/// track (a long mix with per-song timestamps) — appends the current section's
/// name after a "·", tinted, so you see both "Mix Title · Current Song" on one
/// scrolling line. Observing the clock here keeps the ~10 Hz chapter updates scoped
/// to this one line rather than re-rendering the whole window.
struct NowPlayingTitle: View {
    @ObservedObject var clock: PlaybackClock
    let track: Track?
    let isScrubbing: Bool
    let scrubTime: TimeInterval
    let paused: Bool

    private var title: String {
        track?.displayTitle ?? "No track playing"
    }

    /// The "  ·  Current Chapter" suffix, or empty when the track isn't chaptered
    /// or the current section has no title.
    private var chapterSuffix: String {
        guard let track, !track.chapters.isEmpty else { return "" }
        let time = isScrubbing ? scrubTime : clock.currentTime
        if let name = track.chapters.last(where: { $0.start <= time + 0.001 })?.title,
           !name.isEmpty {
            return "  ·  \(name)"
        }
        return ""
    }

    var body: some View {
        MarqueeText(text: title, fontSize: 15, bold: true, color: .white,
                    suffix: chapterSuffix, suffixColor: Theme.logo, paused: paused)
            .copyOnClick(title, help: "Click to copy title", enabled: track != nil)
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
