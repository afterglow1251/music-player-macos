import Foundation
import Darwin

/// Thread-safe string accumulator for subprocess output collected off the main thread.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Downloads audio from a URL (YouTube etc.) by shelling out to `yt-dlp`,
/// keeping the source's native AAC stream as m4a (no re-encode) with embedded
/// artwork and metadata; only sources with no m4a stream get transcoded.
///
/// GUI apps don't inherit the shell's PATH, so we locate the binaries in the
/// usual Homebrew/system locations and pass an explicit PATH to the subprocess.
@MainActor
final class Downloader: ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0      // 0...1
    @Published var status: String = ""
    /// True during the post-download extract/embed phase (ExtractAudio + thumbnail
    /// and metadata), used to surface a "Processing…" status. Cancelling here is
    /// safe now: the intermediate lives in staging and is discarded on abort.
    @Published private(set) var isConverting = false
    /// Set on a failure so the UI can show a transient error toast.
    @Published var lastError: String?
    /// Set for a transient, non-error info toast (e.g. "Already in library").
    @Published var notice: String?

    private let ytDlpPath: String?
    private let toolsDir: String
    private var currentProcess: Process?
    private var cancelled = false

    init() {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        ytDlpPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        toolsDir = ytDlpPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin"
    }

    var isAvailable: Bool { ytDlpPath != nil }

    /// Cancel the in-flight download, if any.
    func cancel() {
        cancelled = true
        let process = currentProcess
        process?.terminate()   // SIGTERM
        // Escalate to SIGKILL if it's still alive after a short grace window.
        // Scheduled off the main actor so it never blocks, and gated on the
        // captured instance's `isRunning` so we never signal a bare, recycled PID.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func beginChecking() {
        cancelled = false
        lastError = nil
        isDownloading = true
        progress = 0
        status = "Checking…"
    }

    func finishChecking(message: String) {
        isDownloading = false
        status = message
    }

    /// Fetch the video id (no download) so callers can dedupe against the library.
    func fetchVideoID(_ urlString: String) async -> String? {
        guard let ytDlpPath else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidURL(trimmed) else { return nil }
        let output = OutputBox()
        _ = await run(executable: ytDlpPath,
                      arguments: ["--print", "%(id)s", "--skip-download", "--no-playlist", "--", trimmed],
                      collect: { output.append($0) })
        let id = output.value.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    /// Download `urlString` into `stagingDir` (a fresh, hidden dir the library
    /// hands us). Returns the new m4a's URL on success; the caller adopts it into
    /// the library and discards the staging dir on every exit path.
    func download(_ urlString: String, into stagingDir: URL) async -> URL? {
        guard let ytDlpPath else {
            let message = "yt-dlp not installed (brew install yt-dlp)"
            lastError = message
            status = message
            return nil
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isValidURL(trimmed) else {
            let message = "Download failed — invalid URL"
            lastError = message
            status = message
            return nil
        }

        // Don't reset `cancelled` here — it's cleared once per item in
        // beginChecking(). If the user hit cancel during the checking phase, bail
        // now instead of starting the download.
        if cancelled { status = "Cancelled"; isDownloading = false; return nil }

        lastError = nil
        isDownloading = true
        progress = 0
        status = "Preparing…"
        isConverting = false
        defer { isDownloading = false; isConverting = false }

        // Prefer the native AAC (m4a) stream so the audio is stored bit-exact —
        // no lossy re-encode, no conversion wait. `--audio-format m4a` only
        // transcodes when the fallback (`bestaudio`, e.g. Opus) was the sole
        // option, keeping every download in a container AVFoundation can play.
        let args = ["-f", "bestaudio[ext=m4a]/bestaudio",
                    "-x", "--audio-format", "m4a", "--audio-quality", "0",
                    "--no-playlist", "--embed-thumbnail", "--add-metadata",
                    // Carry over the video's chapters (YouTube builds them from the
                    // description's timestamps) so a long mix stays navigable
                    // section-by-section. No-op when the source has none.
                    "--embed-chapters",
                    // Fill the artist tag from the channel when the video has no
                    // artist of its own (keeps a real artist tag where present).
                    "--parse-metadata", "%(artist,uploader)s:%(artist)s",
                    "--newline",
                    "--ffmpeg-location", toolsDir,
                    "-o", stagingDir.appendingPathComponent("%(title)s [%(id)s].%(ext)s").path,
                    "--", trimmed]

        let output = OutputBox()
        let code = await run(executable: ytDlpPath, arguments: args, collect: { output.append($0) })
        if cancelled {
            status = "Cancelled"
            return nil
        }
        guard code == 0 else {
            lastError = Downloader.errorMessage(for: output.value)
            status = "Failed"
            return nil
        }

        // The staging dir was freshly created for this one download, so the m4a
        // yt-dlp just wrote is the only one in it.
        let produced = (try? FileManager.default.contentsOfDirectory(
            at: stagingDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let result = produced.first { $0.pathExtension.lowercased() == "m4a" }

        status = result != nil ? "Done" : "File not found"
        progress = 1
        return result
    }

    // MARK: Subprocess

    private func run(executable: String, arguments: [String],
                     collect: (@Sendable (String) -> Void)? = nil) async -> Int32 {
        // Already cancelled before we even started — don't launch the process.
        if cancelled { return -1 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(toolsDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                if let collect { collect(text) }
                let percent = Downloader.parsePercent(text)
                let converting = text.contains("[ExtractAudio]") || text.contains("Destination")
                Task { @MainActor in
                    guard let self else { return }
                    if let percent {
                        self.progress = percent / 100
                        self.status = "Downloading \(Int(percent))%"
                        self.isConverting = false
                    } else if converting {
                        self.status = "Processing…"
                        self.isConverting = true
                    }
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            currentProcess = process
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    // MARK: Helpers

    /// Pull the last "NN.N%" progress figure out of a chunk of yt-dlp output.
    nonisolated static func parsePercent(_ text: String) -> Double? {
        var found: Double?
        var scanner = Substring(text)
        while let range = scanner.range(of: #"[0-9]{1,3}(\.[0-9]+)?%"#, options: .regularExpression) {
            let token = scanner[range].dropLast() // drop '%'
            if let value = Double(token) { found = value }
            scanner = scanner[range.upperBound...]
        }
        return found
    }

    /// Map yt-dlp's raw output to a specific, user-facing failure message.
    /// Falls back to the trimmed last non-empty line, or a generic message,
    /// when nothing recognizable is found. Never returns blank.
    nonisolated static func errorMessage(for output: String) -> String {
        let lower = output.lowercased()
        let signatures: [(needle: String, message: String)] = [
            ("private video", "This video is private"),
            ("video unavailable", "Video unavailable — it may have been removed"),
            ("has been removed", "Video unavailable — it may have been removed"),
            ("account associated with this video has been terminated", "Video unavailable — the uploader's account was terminated"),
            ("not available in your country", "This video is region-locked and unavailable in your country"),
            ("blocked it in your country", "This video is region-locked and unavailable in your country"),
            ("sign in to confirm your age", "This video is age-restricted and requires sign-in"),
            ("age-restricted", "This video is age-restricted and requires sign-in"),
            ("sign in to confirm you're not a bot", "YouTube requires sign-in to confirm you're not a bot"),
            ("temporary failure in name resolution", "Network error — check your internet connection"),
            ("could not resolve host", "Network error — check your internet connection"),
            ("network is unreachable", "Network error — check your internet connection"),
            ("no space left on device", "Download failed — disk is full"),
        ]
        for (needle, message) in signatures where lower.contains(needle) {
            return message
        }
        let lastLine = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        if let lastLine, !lastLine.isEmpty {
            return lastLine
        }
        return "Download failed — check the URL or run: brew upgrade yt-dlp"
    }

    /// Only accept http/https — rejects empty schemes, `file:`, and anything
    /// else that could otherwise be mistaken for a yt-dlp flag (e.g. `-o...`).
    private func isValidURL(_ string: String) -> Bool {
        guard let scheme = URL(string: string)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
