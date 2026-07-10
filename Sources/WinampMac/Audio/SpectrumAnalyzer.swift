import Foundation
import Accelerate

/// Turns raw audio samples into Winamp-style spectrum bars.
///
/// The analyzer is fed samples from the audio tap (a realtime thread) and is
/// read from the render loop (main thread). Access to the shared sample buffer
/// is guarded by a lock, so the class is safe to touch from both — hence
/// `@unchecked Sendable`.
///
/// The "Winamp look" comes from two pieces of physics applied every frame:
///   * bars fall quickly toward the current spectrum value (fast decay),
///   * peak markers snap up instantly, then sink slowly with gravity.
final class SpectrumAnalyzer: @unchecked Sendable {

    // MARK: Configuration

    /// Number of vertical bars. Classic Winamp draws ~19 in the small window.
    let barCount: Int
    /// FFT window size (power of two). 512 ≈ the 576-sample block Winamp vis uses.
    private let fftSize: Int

    /// How far a bar may fall per second (in 0...1 units). Big = snappy.
    var barFalloffPerSecond: Float = 3.2
    /// Initial peak sink speed and how fast it accelerates (gravity).
    var peakGravity: Float = 1.6

    // MARK: FFT state

    private let log2n: vDSP_Length
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var hannWindow: [Float]

    private var realPart: [Float]
    private var imagPart: [Float]
    private var windowedInput: [Float]
    private var magnitudes: [Float]

    /// Precomputed [start, end) FFT-bin ranges for each bar (log-spaced).
    private let barBins: [(lower: Int, upper: Int)]

    // MARK: Shared buffer (written by audio tap, read by render loop)

    private let lock = NSLock()
    private var sampleRing: [Float]
    private var latestWaveform: [Float]

    // MARK: Physics state (render loop only)

    private var barValues: [Float]
    private var peakValues: [Float]
    private var peakVelocities: [Float]
    private var lastRenderTime: CFTimeInterval = 0

    /// Smoothed low-frequency energy (0...1), for artwork "breathing".
    private(set) var bassLevel: Float = 0

    // MARK: Init

    init(barCount: Int = 19, fftSize: Int = 512) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.barCount = barCount
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!

        self.hannWindow = vDSP.window(ofType: Float.self,
                                      usingSequence: .hanningDenormalized,
                                      count: fftSize,
                                      isHalfWindow: false)

        self.realPart = [Float](repeating: 0, count: fftSize / 2)
        self.imagPart = [Float](repeating: 0, count: fftSize / 2)
        self.windowedInput = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)

        self.sampleRing = [Float](repeating: 0, count: fftSize)
        self.latestWaveform = [Float](repeating: 0, count: fftSize)

        self.barValues = [Float](repeating: 0, count: barCount)
        self.peakValues = [Float](repeating: 0, count: barCount)
        self.peakVelocities = [Float](repeating: 0, count: barCount)

        // Log-spaced bin grouping: low frequencies get a few bins, highs get many.
        // This matches how Winamp's bars feel — bass on the left, treble on the right.
        let binCount = fftSize / 2
        var bins: [(Int, Int)] = []
        let minBin = 1.0
        let maxBin = Double(binCount)
        for i in 0..<barCount {
            let lo = minBin * pow(maxBin / minBin, Double(i) / Double(barCount))
            let hi = minBin * pow(maxBin / minBin, Double(i + 1) / Double(barCount))
            let lower = Int(lo)
            let upper = max(lower + 1, Int(hi))
            bins.append((lower, min(upper, binCount)))
        }
        self.barBins = bins
    }

    // MARK: Feeding audio (called from the realtime tap thread)

    /// Store the most recent `fftSize` samples for the next render.
    func ingest(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        if samples.count >= fftSize {
            // Keep the tail (newest samples).
            let start = samples.count - fftSize
            for i in 0..<fftSize {
                sampleRing[i] = samples[start + i]
            }
        } else {
            // Shift old samples left, append the new ones.
            let keep = fftSize - samples.count
            for i in 0..<keep {
                sampleRing[i] = sampleRing[i + samples.count]
            }
            for i in 0..<samples.count {
                sampleRing[keep + i] = samples[i]
            }
        }
        latestWaveform = sampleRing
    }

    // MARK: Rendering (called from the main render loop)

    struct Frame {
        var bars: [Float]   // 0...1, current bar heights
        var peaks: [Float]  // 0...1, falling peak markers
    }

    /// Advance the physics to `time` and return the current bar/peak heights.
    func render(at time: CFTimeInterval) -> Frame {
        let dt: Float
        if lastRenderTime == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = Float(min(max(time - lastRenderTime, 0), 0.1))
        }
        lastRenderTime = time

        let spectrum = computeSpectrum()

        for i in 0..<barCount {
            // Bars: jump up instantly, fall smoothly.
            if spectrum[i] >= barValues[i] {
                barValues[i] = spectrum[i]
            } else {
                barValues[i] = max(spectrum[i], barValues[i] - barFalloffPerSecond * dt)
            }

            // Peaks: snap to a new high, otherwise sink with accelerating gravity.
            if barValues[i] >= peakValues[i] {
                peakValues[i] = barValues[i]
                peakVelocities[i] = 0
            } else {
                peakVelocities[i] += peakGravity * dt
                peakValues[i] = max(0, peakValues[i] - peakVelocities[i] * dt)
            }
        }

        // Bass = mean of the lowest few bands, smoothed for a gentle pulse.
        let bassBands = min(4, barCount)
        var bass: Float = 0
        for i in 0..<bassBands { bass += barValues[i] }
        bass /= Float(bassBands)
        bassLevel += (bass - bassLevel) * min(1, dt * 8)

        return Frame(bars: barValues, peaks: peakValues)
    }

    /// A copy of the latest waveform, normalized to roughly -1...1 for the scope.
    func waveform() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return latestWaveform
    }

    // MARK: FFT

    private func computeSpectrum() -> [Float] {
        // Snapshot the shared samples so we don't hold the lock during the FFT.
        lock.lock()
        let input = sampleRing
        lock.unlock()

        // Apply the Hann window to reduce spectral leakage.
        vDSP.multiply(input, hannWindow, result: &windowedInput)

        let halfN = fftSize / 2
        var spectrum = [Float](repeating: 0, count: barCount)

        windowedInput.withUnsafeBufferPointer { inputPtr in
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!,
                                                       imagp: imagPtr.baseAddress!)

                    // Pack the real input into split-complex form (evens→real, odds→imag).
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }

                    fft.forward(input: splitComplex, output: &splitComplex)

                    // Magnitude of each bin.
                    vDSP.absolute(splitComplex, result: &magnitudes)
                }
            }
        }

        // Group bins into bars, convert to dB, normalize to 0...1.
        let scale = 2.0 / Float(fftSize)
        for i in 0..<barCount {
            let (lo, hi) = barBins[i]
            var sum: Float = 0
            for b in lo..<hi {
                sum += magnitudes[b]
            }
            let avg = (sum / Float(max(1, hi - lo))) * scale

            // dB scaling gives the lively, music-reactive motion Winamp has.
            let db = 20 * log10(avg + 1e-7)
            let normalized = (db + 60) / 60   // map -60...0 dB → 0...1
            spectrum[i] = min(max(normalized, 0), 1)
        }

        return spectrum
    }
}
