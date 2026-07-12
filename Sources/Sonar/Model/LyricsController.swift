import Foundation
import Combine

/// Holds the synced lyrics for whatever's playing, fetching them (local `.lrc`
/// first, then LRCLIB) whenever the track changes.
@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case idle          // nothing playing
        case loading       // cache miss — searching the network, spinner warranted
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

        // Cache first — a fast synchronous local read. On a hit the lyrics appear in
        // the same update as the track change: no spinner, no flash, and the previous
        // song's text is replaced outright rather than lingering. Most switches hit
        // this path (a track played once is cached beside its file).
        if let cached = LyricsProvider.cached(for: track) {
            lines = cached
            state = .loaded
            return
        }

        // Cache miss → we actually have to search the network, so the spinner is
        // honest here (not a one-frame blink on an instant cached load).
        lines = []
        state = .loading
        loadTask = Task { [weak self] in
            let fetched = await LyricsProvider.fetchRemote(for: track)
            guard !Task.isCancelled, let self, self.loadedURL == track.url else { return }
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
