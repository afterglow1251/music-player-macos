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
    @Published private(set) var trackTitle: String = "WINAMP MAC"
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

    // MARK: Engine

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Frame offset applied by the most recent seek, so `currentTime` stays correct.
    private var seekFrame: AVAudioFramePosition = 0

    private var progressTimer: Timer?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        installTap()
    }

    // MARK: Loading

    func load(url: URL) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            duration = Double(totalFrames) / sampleRate
            seekFrame = 0
            currentTime = 0
            trackTitle = url.deletingPathExtension().lastPathComponent.uppercased()

            // Reconnect the player using the file's format so playback is correct.
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

            schedule(from: 0)
            play()
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
            startProgressTimer()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player.stop()
        isPlaying = false
        stopProgressTimer()
        currentTime = 0
        seekFrame = 0
        if audioFile != nil { schedule(from: 0) }
    }

    /// Seek to `time` seconds and keep playing if we were playing.
    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let wasPlaying = isPlaying
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
        file.framePosition = frame
        player.scheduleSegment(file,
                               startingFrame: frame,
                               frameCount: remaining,
                               at: nil)
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
        let played = Double(seekFrame + playerTime.sampleTime) / sampleRate
        currentTime = min(max(0, played), duration)
        if currentTime >= duration, duration > 0 {
            stop()
            onFinished?()
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
