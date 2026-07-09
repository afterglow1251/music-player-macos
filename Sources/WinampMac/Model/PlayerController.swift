import Foundation
import Combine

/// The top-level coordinator the UI observes. Owns the audio engine, the music
/// library, and the downloader, and wires them together (auto-advance, play by
/// track, download-then-play).
@MainActor
final class PlayerController: ObservableObject {
    let engine = AudioEngine()
    let library = MusicLibrary()
    let downloader = Downloader()

    @Published private(set) var currentTrack: Track?
    @Published var urlInput: String = ""

    private var cancellables = Set<AnyCancellable>()

    init() {
        engine.onFinished = { [weak self] in self?.next() }

        // Re-publish child changes so a view observing only the controller still
        // updates when the engine/library/downloader change.
        for child in [engine.objectWillChange,
                      library.objectWillChange,
                      downloader.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                 .store(in: &cancellables)
        }
    }

    // MARK: Playback

    func play(_ track: Track) {
        currentTrack = track
        engine.load(url: track.url)
    }

    /// Play/pause. If nothing is loaded yet, start the first track in the library.
    func togglePlayPause() {
        if currentTrack == nil {
            if let first = library.tracks.first { play(first) }
            return
        }
        engine.togglePlayPause()
    }

    func delete(_ track: Track) {
        if currentTrack == track {
            engine.stop()
            currentTrack = nil
        }
        library.delete(track)
    }

    func next() {
        guard let index = currentIndex else {
            if let first = library.tracks.first { play(first) }
            return
        }
        let nextIndex = index + 1
        if nextIndex < library.tracks.count {
            play(library.tracks[nextIndex])
        } else {
            engine.stop()   // end of library
        }
    }

    func previous() {
        // Restart the track if we're more than 3s in, otherwise go back one.
        if engine.currentTime > 3 {
            engine.seek(to: 0)
            return
        }
        guard let index = currentIndex, index > 0 else { return }
        play(library.tracks[index - 1])
    }

    private var currentIndex: Int? {
        guard let track = currentTrack else { return nil }
        return library.tracks.firstIndex(of: track)
    }

    // MARK: Download

    func downloadFromInput() {
        let url = urlInput
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            guard let fileURL = await downloader.download(url, into: library.folder) else { return }
            let track = await library.add(fileURL)
            urlInput = ""
            play(track)
        }
    }
}
