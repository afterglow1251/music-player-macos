import Foundation
import AVFoundation

/// Plays local audio files and feeds the spectrum analyzer.
///
/// Built on AVAudioEngine → AVAudioPlayerNode. A tap on the main mixer streams
/// samples into `analyzer` on a realtime thread; UI state (`isPlaying`, time,
/// title) is published on the main actor.
@MainActor
final class AudioEngine: ObservableObject {

    // MARK: Published UI state

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var trackTitle: String = "SONAR"
    @Published var volume: Float = 0.75 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    var isMuted: Bool { volume == 0 }
    private var volumeBeforeMute: Float = 0.75

    /// Mute (remembering the level) or restore the previous level.
    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 0.5
        }
    }

    let analyzer = SpectrumAnalyzer()

    /// Called when the current track plays to its end (for auto-advance).
    var onFinished: (() -> Void)?

    // MARK: Equalizer

    /// Standard 10-band center frequencies (Hz).
    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Per-band gain in dB (-12...+12). Setting this updates the audio units live.
    @Published var eqGains: [Float] = Array(repeating: 0, count: 10) {
        didSet { applyEQGains() }
    }
    @Published var eqEnabled: Bool = true {
        didSet { applyEQGains() }
    }

    private func applyEQGains() {
        for (i, band) in eq.bands.enumerated() where i < eqGains.count {
            band.gain = eqEnabled ? eqGains[i] : 0
        }
    }

    // MARK: Engine

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)

    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Frame offset applied by the most recent seek, so `currentTime` stays correct.
    private var seekFrame: AVAudioFramePosition = 0

    private var progressTimer: Timer?

    // MARK: Gapless

    /// The next track, opened and queued back-to-back on the same node so it
    /// starts sample-accurately when the current one ends — no stop/reload seam.
    private struct Scheduled {
        let url: URL
        let file: AVAudioFile
        let frames: AVAudioFramePosition
        let sampleRate: Double
        let duration: TimeInterval
        let title: String
    }
    private var pendingAdvance: Scheduled?
    /// Frames of already-finished segments since the last hard reset. The node's
    /// sampleTime never resets across a seamless join, so `currentTime` subtracts
    /// this to measure only into the current track.
    private var basePlayed: AVAudioFramePosition = 0
    /// Frame count of the current track's scheduled segment.
    private var currentFrames: AVAudioFramePosition = 0
    /// Bumped on every hard reset (load/stop/seek) so a completion callback from a
    /// flushed segment is ignored when it fires late.
    private var generation = 0
    private var didPreschedule = false
    /// Preload the next track this many seconds before the current one ends.
    private let prescheduleLead: TimeInterval = 5

    /// Supplies the URL that will play next (for gapless preloading), or nil to
    /// let playback stop / fall back to the non-gapless path. Set by the controller.
    var nextURLProvider: (() -> URL?)?
    /// Called when playback advances gaplessly to the prescheduled next track, so
    /// the controller can reconcile its state without triggering a reload.
    var onAdvanced: ((URL) -> Void)?

    init() {
        engine.attach(player)
        engine.attach(eq)
        configureEQBands()
        // Chain: player → EQ → main mixer. The tap sits on the mixer, so the
        // visualizer reflects the equalized sound.
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        installTap()
    }

    private func configureEQBands() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = false
        }
    }

    // MARK: Loading

    func load(url: URL, autoplay: Bool = true) {
        hardReset()
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            duration = Double(totalFrames) / sampleRate
            seekFrame = 0
            currentTime = 0
            trackTitle = url.deletingPathExtension().lastPathComponent.uppercased()

            // Reconnect the whole chain with the file's format so the EQ passes
            // audio through correctly (a format mismatch silences the output).
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(eq)
            engine.connect(player, to: eq, format: file.processingFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)

            schedule(from: 0)
            if autoplay { play() }
        } catch {
            trackTitle = "CANNOT OPEN FILE"
        }
    }

    // MARK: Transport

    func play() {
        guard audioFile != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
            isPlaying = true
            analyzer.isRunning = true
            startProgressTimer()
        } catch {
            NSLog("[Sonar] play() failed: \(error)")
            isPlaying = false
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        analyzer.isRunning = false
        stopProgressTimer()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        hardReset()
        if audioFile != nil { schedule(from: 0) }   // re-arm so a later play() works
    }

    /// Stop the node and drop all gapless bookkeeping, WITHOUT rescheduling.
    /// Bumping the generation invalidates any completion callback still pending
    /// from a segment that's about to be flushed. Callers that need playback
    /// re-armed (stop/seek/load) schedule right afterwards.
    private func hardReset() {
        generation += 1
        pendingAdvance = nil
        didPreschedule = false
        basePlayed = 0
        player.stop()
        isPlaying = false
        analyzer.isRunning = false
        stopProgressTimer()
        currentTime = 0
        seekFrame = 0
    }

    /// Seek to `time` seconds and keep playing if we were playing.
    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        // If a next track was prescheduled and the node's real-time clock has
        // already rolled into it, promote it first. Otherwise a seek landing
        // right at the natural track boundary races the (still in-flight)
        // completion callback: this call would invalidate it via `generation`
        // and reschedule from the stale old track while the new one keeps
        // audibly playing underneath.
        reconcileIfAlreadyAdvanced()

        let wasPlaying = isPlaying
        // A seek is a hard reset of the node's timeline: invalidate any gapless
        // preschedule and clear the played-frames base before rescheduling.
        generation += 1
        pendingAdvance = nil
        didPreschedule = false
        basePlayed = 0
        player.stop()

        let target = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        seekFrame = target
        currentTime = Double(target) / sampleRate
        schedule(from: target)

        if wasPlaying { play() } else { isPlaying = false }
        _ = file
    }

    // MARK: Scheduling

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        let remaining = AVAudioFrameCount(max(0, totalFrames - frame))
        guard remaining > 0 else { return }
        currentFrames = AVAudioFramePosition(remaining)
        file.framePosition = frame
        let gen = generation
        player.scheduleSegment(file,
                               startingFrame: frame,
                               frameCount: remaining,
                               at: nil,
                               completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.segmentFinished(gen) }
        }
    }

    /// Open the upcoming track and queue it back-to-back on the same node so it
    /// starts the instant the current one ends. Same-format only — appending to a
    /// live node can't change format, so a differing sample rate / channel count
    /// is left for the normal load path (a seam only on that rare transition).
    private func prescheduleNext() {
        guard pendingAdvance == nil, let current = audioFile,
              let url = nextURLProvider?(),
              let file = try? AVAudioFile(forReading: url) else { return }
        let next = file.processingFormat, cur = current.processingFormat
        guard next.sampleRate == cur.sampleRate, next.channelCount == cur.channelCount else { return }
        let gen = generation
        file.framePosition = 0
        player.scheduleSegment(file,
                               startingFrame: 0,
                               frameCount: AVAudioFrameCount(file.length),
                               at: nil,
                               completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.segmentFinished(gen) }
        }
        pendingAdvance = Scheduled(url: url, file: file, frames: file.length,
                                   sampleRate: next.sampleRate,
                                   duration: Double(file.length) / next.sampleRate,
                                   title: url.deletingPathExtension().lastPathComponent.uppercased())
    }

    /// A scheduled segment finished playing. If a next track was prescheduled it's
    /// already flowing — promote it to current (gaplessly); otherwise this is a
    /// real end-of-track with nothing queued, so signal auto-advance.
    private func segmentFinished(_ gen: Int) {
        guard gen == generation else { return }   // a flushed / stale segment
        if pendingAdvance != nil {
            promoteAdvance()
        } else {
            onFinished?()
        }
    }

    /// If the node's real-time clock has already crossed into a prescheduled next
    /// segment — even though `segmentFinished` hasn't run for it yet — catch our
    /// Swift-level state up to reality. Called before a seek so it can't race the
    /// completion callback and reschedule from a track that's no longer current.
    private func reconcileIfAlreadyAdvanced() {
        guard pendingAdvance != nil,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime - basePlayed >= currentFrames else { return }
        promoteAdvance()
    }

    /// Promote the prescheduled next track to current, gaplessly — the audio is
    /// already flowing; this only syncs the bookkeeping (duration, title, etc).
    private func promoteAdvance() {
        guard let next = pendingAdvance else { return }
        basePlayed += currentFrames             // the node's clock keeps running
        audioFile = next.file
        totalFrames = next.frames
        currentFrames = next.frames
        duration = next.duration
        sampleRate = next.sampleRate
        seekFrame = 0
        currentTime = 0
        trackTitle = next.title
        pendingAdvance = nil
        didPreschedule = false
        onAdvanced?(next.url)
    }

    // MARK: Progress

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        // The node's sampleTime spans every gapless segment since the last hard
        // reset; subtract the finished frames to get the position in THIS track.
        let intoCurrent = playerTime.sampleTime - basePlayed
        currentTime = min(max(0, Double(seekFrame + intoCurrent) / sampleRate), duration)
        // Preload the next track a few seconds before the seam. End-of-track is
        // no longer polled here — the segment completion callback drives advance.
        if isPlaying, !didPreschedule, duration > 0, currentTime >= duration - prescheduleLead {
            didPreschedule = true
            prescheduleNext()
        }
    }

    // MARK: Tap → analyzer

    private func installTap() {
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        // Mark the block @Sendable so Swift does NOT infer main-actor isolation
        // from the enclosing @MainActor type. The tap fires on a realtime audio
        // thread; a main-actor-isolated block would trap on the executor check.
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [analyzer] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let ptr = UnsafeBufferPointer(start: channelData[0], count: frames)
            analyzer.ingest(ptr)
        }
    }
}
