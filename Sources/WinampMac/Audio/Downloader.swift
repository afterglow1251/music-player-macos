import Foundation

/// Downloads audio from a URL (YouTube etc.) by shelling out to `yt-dlp`,
/// converting to mp3 with embedded artwork and metadata via `ffmpeg`.
///
/// GUI apps don't inherit the shell's PATH, so we locate the binaries in the
/// usual Homebrew/system locations and pass an explicit PATH to the subprocess.
@MainActor
final class Downloader: ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0      // 0...1
    @Published var status: String = ""

    private let ytDlpPath: String?
    private let toolsDir: String

    init() {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        ytDlpPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        toolsDir = ytDlpPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin"
    }

    var isAvailable: Bool { ytDlpPath != nil }

    /// Download `urlString` into `folder`. Returns the new mp3's URL on success.
    func download(_ urlString: String, into folder: URL) async -> URL? {
        guard let ytDlpPath else {
            status = "yt-dlp not installed (brew install yt-dlp)"
            return nil
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isDownloading = true
        progress = 0
        status = "Preparing…"
        defer { isDownloading = false }

        let before = files(in: folder)

        let args = ["-x", "--audio-format", "mp3", "--audio-quality", "0",
                    "--no-playlist", "--embed-thumbnail", "--add-metadata",
                    "--newline",
                    "--ffmpeg-location", toolsDir,
                    "-o", folder.appendingPathComponent("%(title)s.%(ext)s").path,
                    trimmed]

        let code = await run(executable: ytDlpPath, arguments: args)
        guard code == 0 else {
            status = "Download failed (code \(code))"
            return nil
        }

        // yt-dlp doesn't cleanly report the final path, so diff the folder.
        let after = files(in: folder)
        let added = after.subtracting(before).filter { $0.pathExtension.lowercased() == "mp3" }
        let result = added.first
            ?? after.filter { $0.pathExtension.lowercased() == "mp3" }
                    .max { modDate($0) < modDate($1) }

        status = result != nil ? "Done" : "File not found"
        progress = 1
        return result
    }

    // MARK: Subprocess

    private func run(executable: String, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
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
                let percent = Downloader.parsePercent(text)
                let converting = text.contains("[ExtractAudio]") || text.contains("Destination")
                Task { @MainActor in
                    guard let self else { return }
                    if let percent { self.progress = percent / 100; self.status = "Downloading \(Int(percent))%" }
                    else if converting { self.status = "Converting to mp3…" }
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

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

    private func files(in folder: URL) -> Set<URL> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(urls)
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
