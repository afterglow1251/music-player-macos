import SwiftUI

/// Synced lyrics that scroll with playback, filling the hero area (like Settings).
/// The active line is highlighted and kept centered; the rest dim with distance.
struct LyricsView: View {
    @ObservedObject var controller: PlayerController
    var width: CGFloat
    var height: CGFloat

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent

    private var activeIndex: Int? {
        controller.lyrics.activeIndex(at: engine.currentTime)
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
                VStack(alignment: .leading, spacing: 12) {
                    // Top/bottom padding so the first and last lines can center.
                    Color.clear.frame(height: height * 0.4)
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
