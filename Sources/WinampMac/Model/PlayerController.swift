import Foundation
import Combine

enum RepeatMode: Int {
    case off = 0, all, one
}

enum SleepMode: Equatable {
    case off
    case timer(minutes: Int)
    case endOfTrack
}

/// The top-level coordinator the UI observes. Owns the audio engine, the music
/// library, the downloader and Now Playing; wires them together and persists
/// playback preferences between launches.
@MainActor
final class PlayerController: ObservableObject {
    let engine = AudioEngine()
    let library = MusicLibrary()
    let downloader = Downloader()
    private let nowPlaying = NowPlayingController()

    @Published private(set) var currentTrack: Track?
    @Published var urlInput: String = ""

    @Published var shuffle = false { didSet { save() } }
    @Published var repeatMode: RepeatMode = .off { didSet { save() } }
    @Published var themeIndex = 0 { didSet { save() } }

    var theme: VisualizerTheme {
        VisualizerTheme.all[min(max(themeIndex, 0), VisualizerTheme.all.count - 1)]
    }

    func cycleTheme() { themeIndex = (themeIndex + 1) % VisualizerTheme.all.count }
    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    init() {
        restorePreferences()

        engine.onFinished = { [weak self] in self?.next(auto: true) }

        // Media keys / Control Center → us.
        nowPlaying.onPlay = { [weak self] in self?.engine.play() }
        nowPlaying.onPause = { [weak self] in self?.engine.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }

        // Re-publish child changes so the view updates.
        for child in [engine.objectWillChange, library.objectWillChange, downloader.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        // Keep Now Playing in sync with play/pause, and remember the position
        // whenever playback pauses/resumes/stops (cheap, no timer).
        engine.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateNowPlaying()
                self?.save()
            }
            .store(in: &cancellables)

        // Persist volume / EQ shortly after the user stops adjusting them.
        engine.$volume.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &cancellables)
        engine.$eqGains.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &cancellables)
        engine.$eqEnabled.dropFirst().sink { [weak self] _ in self?.save() }.store(in: &cancellables)

        // When the library first loads, restore the last-played track (paused).
        library.$tracks.filter { !$0.isEmpty }.first()
            .sink { [weak self] tracks in self?.restoreLastTrack(from: tracks) }
            .store(in: &cancellables)

        // Persist the position every few seconds while playing, so it survives
        // any kind of close (⌘Q, crash, kill) without a per-frame cost.
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.isPlaying else { return }
                self.save()
            }
        }
    }

    private var persistTimer: Timer?

    // MARK: Playback

    func play(_ track: Track) {
        currentTrack = track
        engine.load(url: track.url)
        updateNowPlaying()
        save()
    }

    /// Play/pause. If nothing is loaded yet, start the first track in the library.
    func togglePlayPause() {
        if currentTrack == nil {
            if let first = library.tracks.first { play(first) }
            return
        }
        engine.togglePlayPause()
    }

    func next(auto: Bool = false) {
        // Sleep "until end of track": stop here instead of advancing.
        if auto, sleepMode == .endOfTrack {
            setSleep(.off)
            return
        }
        guard !library.tracks.isEmpty else { return }
        if auto, repeatMode == .one, let track = currentTrack { play(track); return }

        guard let index = currentIndex else { play(library.tracks[0]); return }

        if shuffle {
            play(randomTrack(excluding: index))
            return
        }
        let nextIndex = index + 1
        if nextIndex < library.tracks.count {
            play(library.tracks[nextIndex])
        } else if repeatMode == .all {
            play(library.tracks[0])
        } else if auto {
            engine.stop()                       // reached the end
        } else {
            play(library.tracks[0])             // manual next wraps around
        }
    }

    func previous() {
        if engine.currentTime > 3 { engine.seek(to: 0); return }
        guard !library.tracks.isEmpty, let index = currentIndex else { return }
        if shuffle { play(randomTrack(excluding: index)); return }
        play(library.tracks[index > 0 ? index - 1 : library.tracks.count - 1])
    }

    func delete(_ track: Track) {
        if currentTrack == track {
            engine.stop()
            currentTrack = nil
            updateNowPlaying()
        }
        library.delete(track)
    }

    private var currentIndex: Int? {
        guard let track = currentTrack else { return nil }
        return library.tracks.firstIndex(of: track)
    }

    private func randomTrack(excluding index: Int) -> Track {
        guard library.tracks.count > 1 else { return library.tracks[index] }
        var i = index
        while i == index { i = Int.random(in: 0..<library.tracks.count) }
        return library.tracks[i]
    }

    // MARK: EQ

    func applyEQPreset(_ preset: EQPreset) {
        engine.eqGains = preset.gains
        save()
    }

    // MARK: Download

    func downloadFromInput() { download(urlInput) }

    func download(_ text: String) {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            // Skip if we already have a track with this title.
            downloader.beginChecking()
            if let title = await downloader.fetchTitle(url),
               let existing = library.tracks.first(where: {
                   $0.displayTitle.caseInsensitiveCompare(title) == .orderedSame
               }) {
                downloader.finishChecking(message: "Already in library")
                urlInput = ""
                play(existing)
                return
            }

            guard let fileURL = await downloader.download(url, into: library.folder) else { return }
            let track = await library.add(fileURL)
            urlInput = ""
            play(track)
        }
    }

    func cancelDownload() { downloader.cancel() }

    // MARK: Now Playing

    private func updateNowPlaying() {
        nowPlaying.update(track: currentTrack,
                          isPlaying: engine.isPlaying,
                          elapsed: engine.currentTime,
                          duration: engine.duration)
    }

    // MARK: Persistence

    /// Persist everything now — called on quit so an in-progress track's
    /// position is remembered even if it never paused.
    func saveOnQuit() { save() }

    private func save() {
        defaults.set(engine.volume, forKey: "volume")
        defaults.set(engine.eqGains.map(Double.init), forKey: "eqGains")
        defaults.set(engine.eqEnabled, forKey: "eqEnabled")
        defaults.set(shuffle, forKey: "shuffle")
        defaults.set(repeatMode.rawValue, forKey: "repeatMode")
        defaults.set(themeIndex, forKey: "themeIndex")
        // Only touch the last track/position when something is actually loaded —
        // otherwise a save while idle would wipe the value we want to restore.
        if let track = currentTrack {
            defaults.set(track.url.path, forKey: "lastTrack")
            defaults.set(engine.currentTime, forKey: "lastPosition")
        }
    }

    private func restorePreferences() {
        if defaults.object(forKey: "volume") != nil {
            engine.volume = defaults.float(forKey: "volume")
        }
        if let gains = defaults.array(forKey: "eqGains") as? [Double], gains.count == 10 {
            engine.eqGains = gains.map(Float.init)
        }
        engine.eqEnabled = defaults.object(forKey: "eqEnabled") as? Bool ?? true
        shuffle = defaults.bool(forKey: "shuffle")
        repeatMode = RepeatMode(rawValue: defaults.integer(forKey: "repeatMode")) ?? .off
        themeIndex = defaults.integer(forKey: "themeIndex")
    }

    private func restoreLastTrack(from tracks: [Track]) {
        guard currentTrack == nil,
              let path = defaults.string(forKey: "lastTrack"),
              let track = tracks.first(where: { $0.url.path == path }) else { return }
        // Read the saved position BEFORE loading — engine.load() calls stop(),
        // which resets currentTime to 0 and would clobber the stored value.
        let position = defaults.double(forKey: "lastPosition")
        currentTrack = track
        engine.load(url: track.url, autoplay: false)
        if position > 1 { engine.seek(to: position) }
        updateNowPlaying()
    }

    // MARK: Seek & volume (keyboard)

    func seekBy(_ delta: TimeInterval) {
        guard engine.duration > 0 else { return }
        engine.seek(to: min(max(engine.currentTime + delta, 0), engine.duration))
    }

    func adjustVolume(_ delta: Float) {
        engine.volume = min(max(engine.volume + delta, 0), 1)
    }

    // MARK: Sleep timer

    @Published private(set) var sleepMode: SleepMode = .off
    @Published private(set) var sleepRemaining: TimeInterval?  // seconds left (timer mode)
    private var sleepTimer: Timer?

    func setSleep(_ mode: SleepMode) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepMode = mode
        switch mode {
        case .off, .endOfTrack:
            sleepRemaining = nil
        case .timer(let minutes):
            sleepRemaining = TimeInterval(max(1, minutes) * 60)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickSleep() }
            }
        }
    }

    private func tickSleep() {
        guard let remaining = sleepRemaining else { return }
        let next = remaining - 1
        if next <= 0 {
            engine.pause()
            setSleep(.off)
        } else {
            sleepRemaining = next
        }
    }
}
