import Foundation
import Combine

/// Holds the synced lyrics for whatever's playing, fetching them (local `.lrc`
/// first, then LRCLIB) whenever the track changes.
@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case idle          // nothing playing
        case loading
        case loaded
        case unavailable   // looked, found none
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [LyricLine] = []

    private var loadTask: Task<Void, Never>?
    private var loadedURL: URL?

    /// Fetch lyrics for a track (or clear them for nil). No-op if the same track is
    /// already loaded, so seeking/pausing doesn't refetch.
    func load(for track: Track?) {
        guard let track else {
            loadTask?.cancel()
            loadedURL = nil
            lines = []
            state = .idle
            return
        }
        guard track.url != loadedURL else { return }

        loadTask?.cancel()
        loadedURL = track.url
        lines = []
        state = .loading

        loadTask = Task { [weak self] in
            let fetched = await LyricsProvider.fetch(for: track)
            guard !Task.isCancelled else { return }
            guard let self, self.loadedURL == track.url else { return }
            if let fetched {
                self.lines = fetched
                self.state = .loaded
            } else {
                self.state = .unavailable
            }
        }
    }

    /// The line active at `time`, or nil before the first line / when empty.
    func activeIndex(at time: TimeInterval) -> Int? {
        LyricsProvider.activeIndex(in: lines, at: time)
    }
}
