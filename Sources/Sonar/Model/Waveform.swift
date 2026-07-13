import Foundation
import AVFoundation
import Accelerate

/// A track's amplitude envelope, sampled into a fixed number of peaks (left→right
/// in time, each normalized 0...1). Drives the waveform seek bar. `Sendable` so it
/// can be generated off the main actor and handed back across the boundary.
struct Waveform: Sendable, Equatable {
    /// Peak magnitude per column, 0...1. The loudest column is 1 (globally
    /// normalized, like SoundCloud) so quiet and loud tracks both fill the height.
    let peaks: [Float]
}

/// Generates and caches per-track waveforms, mirroring `LyricsProvider`: a cached
/// blob in the hidden `.sonar/` folder beside the audio (so it travels with the
/// library and survives across launches), computed once on a cache miss.
///
/// `nonisolated` throughout — all it touches is file IO and local buffers, so it
/// runs on a background task without hopping to the main actor.
enum WaveformProvider {

    /// Number of sampled columns. ~500 is plenty of detail for a seek bar a few
    /// hundred points wide; the view resamples this down to its pixel width.
    static let bucketCount = 500

    /// Cache-first load: an instant local read, else generate (and cache). Safe to
    /// call off the main actor; the file read is the slow part on a miss.
    nonisolated static func load(for url: URL) -> Waveform? {
        cached(for: url) ?? generateAndCache(for: url)
    }

    /// Synchronous cache-only lookup — a fast local read, no file scan. Lets the
    /// caller show a cached waveform instantly and reserve generation for a miss.
    nonisolated static func cached(for url: URL) -> Waveform? {
        guard let data = try? Data(contentsOf: cacheURL(for: url)), !data.isEmpty else { return nil }
        let peaks = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        return peaks.isEmpty ? nil : Waveform(peaks: peaks)
    }

    // MARK: Generation

    private nonisolated static func generateAndCache(for url: URL) -> Waveform? {
        guard let waveform = generate(for: url) else { return nil }
        writeCache(waveform.peaks, for: url)
        return waveform
    }

    /// Scan the file into `bucketCount` peak columns. Rather than read every sample
    /// (a 10-hour track is billions), we seek to each bucket's start and read a
    /// bounded window, taking its max magnitude — the envelope is locally coherent,
    /// so a window per bucket captures the shape at a fixed, tiny cost regardless of
    /// track length.
    nonisolated static func generate(for url: URL) -> Waveform? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.channelCount > 0 else { return nil }

        let columns = min(bucketCount, Int(total))
        guard columns > 0 else { return nil }
        let framesPerBucket = total / AVAudioFramePosition(columns)
        guard framesPerBucket > 0 else { return nil }
        // Read at most this many frames per bucket — bounds total work to
        // columns × window frames however long the track is.
        let window = AVAudioFrameCount(min(framesPerBucket, 8192))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return nil }

        var peaks = [Float](repeating: 0, count: columns)
        for i in 0..<columns {
            // Bail mid-scan when the track has moved on — the caller cancels this
            // task on every track change, so rapid next/prev doesn't run several
            // full-file scans to completion in parallel.
            if Task.isCancelled { return nil }
            file.framePosition = AVAudioFramePosition(i) * framesPerBucket
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: window) } catch { break }
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { continue }
            // RMS (loudness energy), not peak magnitude: modern loud masters clip
            // near full-scale almost everywhere, so a peak envelope reads as a solid
            // brick. RMS follows perceived loudness, so quiet intros and loud drops
            // show as different heights. Take the louder channel's RMS.
            var bucketRMS: Float = 0
            for c in 0..<Int(format.channelCount) {
                var rms: Float = 0
                vDSP_rmsqv(channels[c], 1, &rms, vDSP_Length(buffer.frameLength))
                bucketRMS = max(bucketRMS, rms)
            }
            peaks[i] = bucketRMS
        }

        // Normalize so the loudest column reaches full height.
        var globalMax: Float = 0
        vDSP_maxv(peaks, 1, &globalMax, vDSP_Length(columns))
        if globalMax > 0 {
            var scale = 1 / globalMax
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(columns))
        }
        return Waveform(peaks: peaks)
    }

    // MARK: On-disk cache (hidden `.sonar/` folder beside the audio)

    /// `<audio dir>/.sonar/<audio filename>.waveform` — same hidden per-folder
    /// subdirectory the lyrics cache uses, keyed on the full filename (extension
    /// included) so same-named tracks of different formats don't collide.
    private nonisolated static func cacheURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent()
            .appendingPathComponent(".sonar", isDirectory: true)
            .appendingPathComponent(audio.lastPathComponent)
            .appendingPathExtension("waveform")
    }

    /// Peaks written as a raw little-endian Float32 blob (500 floats ≈ 2 KB); the
    /// count is implicit in the byte length.
    private nonisolated static func writeCache(_ peaks: [Float], for audio: URL) {
        guard !peaks.isEmpty else { return }
        let url = cacheURL(for: audio)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = peaks.withUnsafeBytes { Data($0) }
        try? data.write(to: url, options: .atomic)
    }
}

/// Holds the current track's waveform for the seek bar, isolated on its own
/// observable (like `PlaybackClock`) so loading one doesn't re-render the rest of
/// the window. A cache hit resolves synchronously; a miss generates on a detached
/// task and is dropped if the track changes before it finishes.
@MainActor
final class WaveformStore: ObservableObject {
    @Published private(set) var waveform: Waveform? {
        didSet { version &+= 1 }
    }

    /// Bumped on every waveform change. A cheap identity the seek bar keys its
    /// prebuilt bar geometry on, so it rebuilds only when the waveform actually
    /// swaps — not on every 10 Hz playback tick that redraws the bar.
    private(set) var version = 0

    /// The track whose waveform we currently want — guards against a slow
    /// generation landing after the user has moved on to another track.
    private var currentURL: URL?

    /// The in-flight generation, if any. Cancelled the moment the track changes so
    /// rapid next/prev doesn't pile up full-file scans that no one is waiting for.
    private var generationTask: Task<Void, Never>?

    /// Point the store at a track (or nil to clear). Synchronous on a cache hit;
    /// otherwise clears immediately and fills in when generation completes.
    func load(for track: Track?) {
        guard let url = track?.url else {
            generationTask?.cancel()
            generationTask = nil
            currentURL = nil
            waveform = nil
            return
        }
        guard url != currentURL else { return }   // already showing / loading this one
        currentURL = url

        // Any prior generation is for a track we've moved off — stop scanning it.
        generationTask?.cancel()
        generationTask = nil

        if let cached = WaveformProvider.cached(for: url) {
            waveform = cached
            return
        }
        waveform = nil
        generationTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            let generated = WaveformProvider.load(for: url)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == url else { return }   // track moved on
                self.waveform = generated
                self.generationTask = nil
            }
        }
    }
}
