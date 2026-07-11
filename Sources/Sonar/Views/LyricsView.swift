import SwiftUI

/// Synced lyrics that scroll with playback, filling the hero area (like Settings).
/// The active line is highlighted and kept centered; the rest dim with distance.
struct LyricsView: View {
    @ObservedObject var controller: PlayerController
    /// Observed directly so the highlighted line tracks playback — currentTime no
    /// longer flows through `controller`, so observing it here keeps the rest of
    /// the app off the ~10 Hz tick.
    @ObservedObject var clock: PlaybackClock
    var width: CGFloat
    var height: CGFloat

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent

    private var activeIndex: Int? {
        controller.lyrics.activeIndex(at: clock.currentTime)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            content
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.lyrics.state {
        case .loading:
            status(spinner: true, "Finding lyrics…")
        case .idle:
            status("Play a track to see its lyrics")
        case .unavailable:
            status("No synced lyrics found")
        case .loaded:
            scroller
        }
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Lazy so the whole song's worth of lines isn't rebuilt on every
                // currentTime tick (the controller republishes ~10×/s); only the
                // visible lines re-evaluate.
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Small top inset so the first line starts near the top; a large
                    // bottom inset so the last line can still center during playback.
                    Color.clear.frame(height: 24)
                    ForEach(Array(controller.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        lineView(line.text, active: index == activeIndex)
                            .id(index)
                            .onTapGesture { engine.seek(to: line.time) }
                    }
                    Color.clear.frame(height: height * 0.4)
                }
                .padding(.horizontal, 22)
                .frame(width: width, alignment: .leading)
            }
            .onChange(of: activeIndex) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                // Opening mid-song: jump straight to the current line instead of
                // waiting for the next activeIndex change to trigger a scroll.
                guard let idx = activeIndex else { return }
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    private func lineView(_ text: String, active: Bool) -> some View {
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: active ? 17 : 15, weight: active ? .bold : .medium))
            .foregroundStyle(active ? accent : .white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.2), value: active)
    }

    private func status(spinner: Bool = false, _ text: String) -> some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6))
            } else {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
