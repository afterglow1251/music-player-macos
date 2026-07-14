import Foundation
import Combine
import AppKit

enum RepeatMode: Int {
    case off = 0, all, one
}

/// One entry in the play queue. The stable `id` lets the same track sit in the
/// queue more than once and keeps drag-reorder animations smooth.
struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    var track: Track
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
    /// The one player the whole app drives — shared by the main window and the
    /// menu-bar mini-player so they stay in lockstep (same engine, same queue).
    static let shared = PlayerController()

    let engine = AudioEngine()
    let library = MusicLibrary()
    let playlists = PlaylistStore()
    let favorites = FavoritesStore()
    let downloader = Downloader()
    let lyrics = LyricsController()
    let waveforms = WaveformStore()
    private let nowPlaying = NowPlayingController()

    @Published private(set) var currentTrack: Track? {
        didSet {
            if currentTrack?.url != oldValue?.url {
                lyrics.load(for: currentTrack)
                waveforms.load(for: currentTrack)
            }
            if currentTrack?.artworkData != oldValue?.artworkData { refreshAlbumTheme() }
        }
    }
    @Published var urlInput: String = ""

    /// Tracks the user lined up to play next, overriding the normal library order.
    /// Ephemeral (not persisted) — like Winamp's play queue. Each entry has a
    /// stable id so the same track can appear twice and drag-reorder stays smooth.
    @Published private(set) var queue: [QueueItem] = []

    @Published var shuffle = false { didSet { resetShuffle(); save() } }
    @Published var repeatMode: RepeatMode = .off { didSet { save() } }
    @Published var themeIndex = 0 { didSet { save() } }

    /// When on, the visualizer tiles are tinted from the current cover instead of
    /// the fixed preset at `themeIndex`.
    @Published var albumTheme = true {
        didSet {
            if albumTheme { refreshAlbumTheme() }
            save()
        }
    }

    /// Theme derived from the current cover (nil when off, or the cover has no
    /// usable color). Cached so tiles don't re-decode the artwork every frame.
    @Published private(set) var derivedAlbumTheme: VisualizerTheme?

    var theme: VisualizerTheme {
        if albumTheme, let derived = derivedAlbumTheme { return derived }
        return VisualizerTheme.all[min(max(themeIndex, 0), VisualizerTheme.all.count - 1)]
    }

    func cycleTheme() {
        albumTheme = false
        themeIndex = (themeIndex + 1) % VisualizerTheme.all.count
    }

    /// Recompute the cover-derived theme. Cheap (downscales to 32×32), and only
    /// runs when album mode is on so idle covers don't burn cycles.
    private func refreshAlbumTheme() {
        guard albumTheme, let data = currentTrack?.artworkData,
              let image = NSImage(data: data) else {
            derivedAlbumTheme = nil
            return
        }
        derivedAlbumTheme = VisualizerTheme.fromArtwork(image)
    }
    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences()

    /// True only while `restorePreferences()` runs. Restoring one `@Published`
    /// (e.g. `shuffle`) fires its `didSet { save() }`, which would persist a
    /// half-restored snapshot — clobbering values not yet restored (the theme
    /// was being reset to Classic this way). Guarding `save()` prevents it.
    private var isRestoring = false

    init() {
        restorePreferences()

        engine.onFinished = { [weak self] in self?.next(auto: true) }

        // Gapless: the engine preloads the next track and, when it advances to it
        // seamlessly, asks us to reconcile state without a reload.
        engine.nextURLProvider = { [weak self] in self?.peekNextURL() }
        engine.onAdvanced = { [weak self] url in self?.commitAdvance(to: url) }

        // Media keys / Control Center → us.
        nowPlaying.onPlay = { [weak self] in self?.engine.play() }
        nowPlaying.onPause = { [weak self] in self?.engine.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }

        // Re-publish child changes so the view updates.
        for child in [engine.objectWillChange, library.objectWillChange,
                      playlists.objectWillChange, favorites.objectWillChange,
                      downloader.objectWillChange, lyrics.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        // When the library rescans (e.g. a download finished writing its tags and
        // artwork), refresh the now-playing track so its cover/title/duration
        // update on their own — without needing a re-play.
        library.$tracks
            .sink { [weak self] tracks in
                guard let self, let current = self.currentTrack,
                      let updated = tracks.first(where: { $0.url == current.url }) else { return }
                if updated.artworkData != current.artworkData
                    || updated.title != current.title
                    || updated.duration != current.duration {
                    self.currentTrack = updated
                    self.updateNowPlaying()
                }
            }
            .store(in: &cancellables)

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

    /// The ordered list we're currently playing through. Playing a group/playlist
    /// sets it to that group's tracks; a plain library tap resets it to the library.
    private var scope: [Track] = []

    // Real shuffle state: a "bag" (every track plays once before any repeat) and a
    // history of what actually played (so ⏮/⏭ step through it rather than re-roll).
    private var shuffleBag: [Track] = []       // upcoming this cycle, pre-shuffled
    private var shuffleHistory: [Track] = []   // played order
    private var shuffleCursor = -1             // index in shuffleHistory of the current track
    private var shuffleUniverse: [Track] = []  // the list the bag was built from

    /// Tracks that next/previous walk through: the active scope if it still holds
    /// the current track, otherwise the whole library.
    private var activeScope: [Track] {
        PlaybackSequencer.activeScope(current: currentTrack, scope: scope, library: library.tracks)
    }

    func play(_ track: Track, in scope: [Track]? = nil) {
        let list = scope ?? library.tracks
        self.scope = list
        currentTrack = track
        syncShuffleHistory(playing: track, in: list)
        engine.load(url: track.url)
        updateNowPlaying()
        save()
    }

    /// Play a whole group (playlist / artist section) as the new scope.
    func playGroup(_ tracks: [Track]) {
        guard let first = tracks.first else { return }
        play(first, in: tracks)
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
        let decision = PlaybackSequencer.nextDecision(
            auto: auto, current: currentTrack, library: library.tracks, scope: scope,
            queueFront: queue.first?.track, shuffle: shuffle, repeatMode: repeatMode,
            sleepUntilEndOfTrack: sleepMode == .endOfTrack)
        switch decision {
        case .none:
            return
        case .stopForSleep:
            setSleep(.off)                          // track ended naturally; just clear the timer
        case .stopAtEnd:
            engine.stop()
        case .play(let track, let scope, let fromQueue):
            if fromQueue { queue.removeFirst(); play(track) }   // queue plays in the library scope
            else { play(track, in: scope) }
        case .playRandom(let list, _, _):
            play(nextShuffleTrack(in: list), in: list)
        }
    }

    func previous() {
        if engine.currentTime > 3 { engine.seek(to: 0); return }
        switch PlaybackSequencer.previousDecision(current: currentTrack, activeScope: activeScope, shuffle: shuffle) {
        case .play(let track, let scope, _):
            play(track, in: scope)
        case .playRandom(let list, _, _):
            if let prev = previousShuffleTrack() { play(prev, in: list) }
            else { engine.seek(to: 0) }   // at the start of shuffle history → restart current
        case .none, .stopForSleep, .stopAtEnd:
            return
        }
    }

    /// The URL that will play next, WITHOUT side effects — the engine preloads it
    /// for a gapless join. Shares `nextDecision` with `next(auto:)`, so the
    /// preloaded track can't disagree with what actually plays. nil when playback
    /// should stop or the transition can't be gapless (shuffle picks at advance).
    private func peekNextURL() -> URL? {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: currentTrack, library: library.tracks, scope: scope,
            queueFront: queue.first?.track, shuffle: shuffle, repeatMode: repeatMode,
            sleepUntilEndOfTrack: sleepMode == .endOfTrack)
        if case .play(let track, _, _) = decision { return track.url }
        return nil
    }

    /// Reconcile our state to a track the engine has already advanced to
    /// gaplessly — no `play()` / reload, the audio is already flowing.
    private func commitAdvance(to url: URL) {
        guard let track = library.tracks.first(where: { $0.url == url }) else { return }
        if queue.first?.track.url == url {
            queue.removeFirst()
            scope = library.tracks          // a queued track plays in the library scope, like play()
        }
        currentTrack = track
        updateNowPlaying()
        save()
    }

    func delete(_ track: Track) {
        guard library.delete(track) else {
            downloader.lastError = "Couldn't move \(track.title) to the Trash"
            return
        }
        if currentTrack == track {
            engine.stop()
            currentTrack = nil
            updateNowPlaying()
        }
        queue.removeAll { $0.track == track }
    }

    /// Delete several tracks (multi-select). Each goes through the same failure-
    /// aware path as the single delete: a track whose Trash move fails stays in the
    /// library, and the toast reports how many couldn't be trashed.
    func delete(_ tracks: [Track]) {
        var failed = 0
        var stoppedCurrent = false
        for track in tracks {
            guard library.delete(track) else { failed += 1; continue }
            if currentTrack == track {
                engine.stop()
                currentTrack = nil
                stoppedCurrent = true
            }
            queue.removeAll { $0.track == track }
        }
        if stoppedCurrent { updateNowPlaying() }
        if failed > 0 {
            downloader.lastError = "Couldn't move \(failed) track\(failed == 1 ? "" : "s") to the Trash"
        }
    }

    // MARK: Queue

    /// Insert a track at the front of the queue — it plays right after the current one.
    func playNext(_ track: Track) { queue.insert(QueueItem(track: track), at: 0) }

    /// Queue several tracks to play next, preserving their order (multi-select).
    func playNext(_ tracks: [Track]) {
        queue.insert(contentsOf: tracks.map { QueueItem(track: $0) }, at: 0)
    }

    /// Append a track to the end of the queue.
    func addToQueue(_ track: Track) { queue.append(QueueItem(track: track)) }

    /// Append several tracks to the queue, in order (multi-select).
    func addToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks.map { QueueItem(track: $0) })
    }

    func removeFromQueue(_ item: QueueItem) { queue.removeAll { $0.id == item.id } }

    /// Gesture reorder: move the queued item with `id` to `index` (queue is
    /// ephemeral, so there's nothing to persist).
    func reorderQueue(id: UUID, toIndex index: Int) {
        guard let from = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: from)
        queue.insert(item, at: min(max(index, 0), queue.count))
    }

    func clearQueue() { queue.removeAll() }

    // MARK: Favorites

    func isFavorite(_ track: Track) -> Bool { favorites.isFavorite(track.url.path) }

    func toggleFavorite(_ track: Track) { favorites.toggle(track.url.path) }

    /// Favorite or unfavorite a set of tracks at once (multi-select).
    func setFavorite(_ tracks: [Track], to favorite: Bool) {
        favorites.setFavorite(Set(tracks.map { $0.url.path }), to: favorite)
    }

    // MARK: Playlists

    /// Resolve a playlist's stored paths to real library tracks, in playlist
    /// order, skipping any file that's no longer in the library.
    func tracks(in playlist: Playlist) -> [Track] {
        let byPath = Dictionary(library.tracks.map { ($0.url.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        return playlist.trackPaths.compactMap { byPath[$0] }
    }

    /// Play a playlist from its first track, as the new scope.
    func playPlaylist(_ playlist: Playlist) {
        playGroup(tracks(in: playlist))
    }

    /// Snapshot the current queue into a new playlist. Returns nil if the queue
    /// is empty (nothing to save).
    @discardableResult
    func saveQueueAsPlaylist() -> Playlist? {
        guard !queue.isEmpty else { return nil }
        let playlist = playlists.create()
        for item in queue { playlists.add(path: item.track.url.path, to: playlist.id) }
        return playlist
    }

    // MARK: Shuffle bag + history

    /// Next track under shuffle: walk forward through history if the user had
    /// stepped back, otherwise draw the next from the bag (refilling+reshuffling it
    /// when empty, so every track plays once before any repeat).
    private func nextShuffleTrack(in list: [Track]) -> Track {
        reseedShuffleIfNeeded(for: list)
        if shuffleCursor >= 0, shuffleCursor + 1 < shuffleHistory.count {
            shuffleCursor += 1                       // ⏮ then ⏭ → forward through history
            return shuffleHistory[shuffleCursor]
        }
        if shuffleBag.isEmpty { refillShuffleBag(avoiding: currentTrack) }
        let track = shuffleBag.popLast() ?? currentTrack ?? list[0]
        shuffleHistory.append(track)
        shuffleCursor = shuffleHistory.count - 1
        return track
    }

    /// Previous track under shuffle — step back through the played history. nil at
    /// the start of history (the caller restarts the current track instead).
    private func previousShuffleTrack() -> Track? {
        guard shuffleCursor > 0 else { return nil }
        shuffleCursor -= 1
        return shuffleHistory[shuffleCursor]
    }

    /// Keep the shuffle history/bag consistent with whatever actually starts
    /// playing. The navigator's own picks are already recorded (a no-op here); a
    /// manual pick / queue / group jump reseeds the history so ⏮ and the bag
    /// continue from the new track.
    private func syncShuffleHistory(playing track: Track, in list: [Track]) {
        guard shuffle else { return }
        if shuffleUniverse == list, shuffleCursor >= 0, shuffleCursor < shuffleHistory.count,
           shuffleHistory[shuffleCursor] == track {
            return
        }
        shuffleUniverse = list
        shuffleHistory = [track]
        shuffleCursor = 0
        refillShuffleBag(avoiding: track)
    }

    /// Rebuild the bag/history when the shuffle universe (the list we walk) changes
    /// — e.g. switching from the library to a playlist.
    private func reseedShuffleIfNeeded(for list: [Track]) {
        guard shuffleUniverse != list else { return }
        shuffleUniverse = list
        shuffleHistory = currentTrack.map { [$0] } ?? []
        shuffleCursor = shuffleHistory.count - 1
        refillShuffleBag(avoiding: currentTrack)
    }

    private func refillShuffleBag(avoiding: Track?) {
        shuffleBag = shuffleUniverse.filter { $0 != avoiding }.shuffled()
    }

    /// Drop all shuffle memory — toggling shuffle re-seeds from the next play.
    private func resetShuffle() {
        shuffleBag = []
        shuffleHistory = []
        shuffleCursor = -1
        shuffleUniverse = []
    }

    // MARK: EQ

    func applyEQPreset(_ preset: EQPreset) {
        engine.eqGains = preset.gains
        save()
    }

    // MARK: Download

    /// One URL sitting in the download queue, staying put (and visible as a chip)
    /// for its whole lifetime — added on submit, removed only once it finishes.
    struct DownloadItem: Identifiable, Equatable {
        let id = UUID()
        let url: String
    }

    /// Everything waiting to download, including the one currently in flight
    /// (always `downloadQueue.first` while `isProcessingDownloads`). Downloads
    /// run one at a time; an item is removed only when its own download ends.
    @Published private(set) var downloadQueue: [DownloadItem] = []
    private var isProcessingDownloads = false

    var downloadsLeft: Int { downloadQueue.count }

    /// The item currently being downloaded, if any — the UI uses this to lock
    /// its chip against removal while the item's own download is in flight.
    var currentDownloadID: DownloadItem.ID? {
        isProcessingDownloads ? downloadQueue.first?.id : nil
    }

    func downloadFromInput() { download(urlInput) }

    /// Enqueue one or many URLs (paste several separated by spaces/newlines).
    /// URLs already queued (or mid-download) are skipped so the same link can't
    /// be queued twice back-to-back.
    func download(_ text: String) {
        var seen = Set(downloadQueue.map(\.url))
        let urls = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { $0.contains("http") }
        var newItems: [DownloadItem] = []
        var skippedOwned = false
        for url in urls {
            if isAlreadyDownloaded(url) { skippedOwned = true; continue }  // instant, no network
            guard seen.insert(url).inserted else { continue }
            newItems.append(DownloadItem(url: url))
        }
        if skippedOwned { downloader.notice = "Already in library" }
        urlInput = ""
        guard !newItems.isEmpty else { return }
        downloadQueue.append(contentsOf: newItems)
        processDownloads()
    }

    /// Instant, no-network check: is this URL's video already in the library?
    /// Only decides for URLs whose id we can parse locally; anything else returns
    /// false here and is resolved for real at download time.
    func isAlreadyDownloaded(_ url: String) -> Bool {
        guard let id = Track.youtubeID(from: url) else { return false }
        return library.tracks.contains { $0.videoID == id }
    }

    /// Is this exact URL already sitting in the download queue (submitted, waiting
    /// or mid-download)? The staging UI combines this with its own not-yet-submitted
    /// chips to decide "shake the existing chip" vs "stage a new one".
    func isQueued(_ url: String) -> Bool {
        downloadQueue.contains { $0.url == url }
    }

    private func processDownloads() {
        guard !isProcessingDownloads, let next = downloadQueue.first else { return }
        isProcessingDownloads = true
        Task {
            await runDownload(next.url)
            downloadQueue.removeAll { $0.id == next.id }
            isProcessingDownloads = false
            processDownloads()          // next in the queue
        }
    }

    private func runDownload(_ url: String) async {
        // Skip if we already have this exact video (matched by its id).
        downloader.beginChecking()
        // Dedupe with the locally-parsed id first; only ask yt-dlp when we can't
        // parse the URL ourselves.
        var videoID = Track.youtubeID(from: url)
        if videoID == nil { videoID = await downloader.fetchVideoID(url) }
        if let videoID, library.tracks.contains(where: { $0.videoID == videoID }) {
            downloader.finishChecking(message: "Already in library")
            downloader.notice = "Already in library"   // surfaced as a toast
            return
        }
        // Stage the download in a hidden dir the watcher never sees, so a
        // half-written file can never appear as a (deletable, race-prone) row.
        // The finished file is adopted into the library; staging is discarded on
        // every exit path — cancel, failure, adopt failure, and success.
        guard let stagingDir = library.makeStagingDir() else {
            downloader.lastError = "Couldn't prepare download"
            return
        }
        guard let fileURL = await downloader.download(url, into: stagingDir) else {
            library.discardStaging(stagingDir)
            return
        }
        // Just add it to the library — don't hijack whatever is currently playing.
        guard await library.adopt(fileURL) != nil else {
            downloader.lastError = "Couldn't add to library"
            library.discardStaging(stagingDir)
            return
        }
        library.discardStaging(stagingDir)
        downloader.notice = "Added to library"          // success toast
    }

    /// Import audio files already on disk (Open File / drag-drop) into the library.
    /// Mirrors a download: add each to the library and surface an "Added" toast,
    /// without hijacking whatever is currently playing.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls { await library.add(url) }
            downloader.notice = urls.count == 1 ? "Added to library" : "Added \(urls.count) to library"
        }
    }

    /// Drop one queued (not-yet-started) item. No-op for the active download —
    /// use `cancelDownload()` to stop that.
    func removeFromQueue(_ id: DownloadItem.ID) {
        guard id != currentDownloadID else { return }
        downloadQueue.removeAll { $0.id == id }
    }

    /// Cancel the current download and clear the whole queue.
    func cancelDownload() {
        downloadQueue.removeAll()
        downloader.cancel()
    }

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
        guard !isRestoring else { return }
        prefs.volume = engine.volume
        prefs.eqGains = engine.eqGains
        prefs.eqEnabled = engine.eqEnabled
        prefs.shuffle = shuffle
        prefs.repeatMode = repeatMode
        prefs.themeName = VisualizerTheme.all[min(max(themeIndex, 0), VisualizerTheme.all.count - 1)].name
        prefs.albumTheme = albumTheme
        // Only touch the last track/position when something is actually loaded —
        // otherwise a save while idle would wipe the value we want to restore.
        if let track = currentTrack {
            prefs.lastTrack = track.url.path
            prefs.lastPosition = engine.currentTime
        }
    }

    private func restorePreferences() {
        isRestoring = true
        defer { isRestoring = false }
        if let volume = prefs.volume { engine.volume = volume }
        if let gains = prefs.eqGains, gains.count == 10 { engine.eqGains = gains }
        engine.eqEnabled = prefs.eqEnabled ?? true
        shuffle = prefs.shuffle
        repeatMode = prefs.repeatMode
        if let name = prefs.themeName,
           let index = VisualizerTheme.all.firstIndex(where: { $0.name == name }) {
            themeIndex = index
        }
        albumTheme = prefs.albumTheme ?? true
    }

    private func restoreLastTrack(from tracks: [Track]) {
        guard currentTrack == nil,
              let path = prefs.lastTrack,
              let track = tracks.first(where: { $0.url.path == path }) else { return }
        // Read the saved position BEFORE loading — engine.load() calls stop(),
        // which resets currentTime to 0 and would clobber the stored value.
        let position = prefs.lastPosition
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
    private var sleepEndDate: Date?
    private var sleepStopTimer: Timer?     // single precise fire that performs the stop
    private var sleepDisplayTimer: Timer?  // 1 Hz UI-only tick; recomputes sleepRemaining from sleepEndDate

    func setSleep(_ mode: SleepMode) {
        sleepStopTimer?.invalidate()
        sleepStopTimer = nil
        sleepDisplayTimer?.invalidate()
        sleepDisplayTimer = nil
        sleepEndDate = nil
        sleepMode = mode
        switch mode {
        case .off, .endOfTrack:
            sleepRemaining = nil
        case .timer(let minutes):
            let interval = TimeInterval(max(1, minutes) * 60)
            let endDate = Date().addingTimeInterval(interval)
            sleepEndDate = endDate
            sleepRemaining = interval

            let stopTimer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fireSleepStop() }
            }
            RunLoop.main.add(stopTimer, forMode: .common)
            sleepStopTimer = stopTimer

            sleepDisplayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickSleepDisplay() }
            }
        }
    }

    private func tickSleepDisplay() {
        guard let endDate = sleepEndDate else { return }
        sleepRemaining = max(0, endDate.timeIntervalSinceNow)
    }

    private func fireSleepStop() {
        engine.pause()
        setSleep(.off)
    }
}
