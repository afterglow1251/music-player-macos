import Foundation

/// The list of tracks in the project's `Music/` folder.
///
/// Scans on startup and after each download. Metadata is read off the main
/// actor (in `Track.load`) and the results are published on the main actor.
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []

    /// The `Music/` folder inside the Swift package.
    let folder: URL

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac"]

    init() {
        folder = Self.projectMusicFolder()
        Task { await scan() }
    }

    /// Reload every audio file in the folder.
    func scan() async {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder,
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        let audioURLs = urls.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }

        var loaded: [Track] = []
        for url in audioURLs {
            loaded.append(await Track.load(from: url))
        }
        tracks = sorted(loaded)
    }

    /// Add a single freshly-downloaded file without rescanning everything.
    @discardableResult
    func add(_ url: URL) async -> Track {
        let track = await Track.load(from: url)
        if let existing = tracks.firstIndex(of: track) {
            tracks[existing] = track
        } else {
            tracks = sorted(tracks + [track])
        }
        return track
    }

    /// Move a track's file to the Trash and drop it from the library.
    func delete(_ track: Track) {
        try? FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
        tracks.removeAll { $0 == track }
    }

    private func sorted(_ list: [Track]) -> [Track] {
        list.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    /// Locate the package's `Music/` folder by walking up from this source file
    /// to the directory that holds `Package.swift`, then create `Music/` there.
    static func projectMusicFolder() -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let music = dir.appendingPathComponent("Music", isDirectory: true)
        try? fm.createDirectory(at: music, withIntermediateDirectories: true)
        return music
    }
}
