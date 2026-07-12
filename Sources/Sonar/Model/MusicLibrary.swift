import Foundation
import AppKit

/// The user's music library. Lives in a normal, Finder-reachable folder
/// (default `~/Documents/Sonar/`, changeable in Settings) and watches that
/// folder so files added/removed in Finder show up without a restart.
///
/// Order is fully manual: drag to arrange, and it persists. Files not yet in the
/// saved order (e.g. a fresh download) sort in alphabetically at the end.
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var folder: URL
    /// How the library is presented (browse order).
    @Published private(set) var view: LibraryView

    private let prefs = Preferences()
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac"]

    // Folder watcher.
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var rescanTask: Task<Void, Never>?

    init() {
        folder = Self.resolveFolder(prefs: Preferences())
        view = prefs.libraryView
        Self.migrateLegacyFiles(into: folder)
        // Clear any staging left behind by a download the app didn't finish
        // (crash/quit) — its contents are junk. Done before watching so the
        // removal doesn't kick off a rescan.
        sweepOrphanedStaging()
        startWatching()
        Task { await scan() }
    }

    deinit { watcher?.cancel() }

    // MARK: Public API

    func revealInFinder() {
        NSWorkspace.shared.open(folder)
    }

    /// Reload every audio file in the folder, **recursing into subfolders** so a
    /// normal Artist/Album/ tree is picked up, not just a flat drop folder.
    func scan() async {
        let fm = FileManager.default
        let audioURLs: [URL]
        if let enumerator = fm.enumerator(at: folder,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            audioURLs = enumerator.compactMap { $0 as? URL }
                .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        } else {
            audioURLs = []
        }

        var loaded: [Track] = []
        for url in audioURLs {
            loaded.append(await Track.load(from: url))
        }
        tracks = arranged(loaded)
    }

    /// Add a single freshly-downloaded file without rescanning everything.
    @discardableResult
    func add(_ url: URL) async -> Track {
        let localURL = bringIntoLibrary(url)
        let track = await Track.load(from: localURL)
        if let existing = tracks.firstIndex(of: track) {
            tracks[existing] = track
        } else {
            tracks = arranged(tracks + [track])
        }
        return track
    }

    /// Ensure an imported file physically lives inside the library folder. Files
    /// added from elsewhere (Open File / drag-drop out of Downloads, etc.) are
    /// copied in, so the library owns its own copy — and, crucially, Trash "Put
    /// Back" returns a deleted track to the library folder rather than to wherever
    /// it was imported from. This matches downloads, which yt-dlp already writes
    /// straight into the folder. Files already inside the folder are referenced
    /// as-is (no copy). On any copy failure we fall back to the original URL so the
    /// import still succeeds.
    private func bringIntoLibrary(_ url: URL) -> URL {
        let fm = FileManager.default
        let folderPath = folder.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(folderPath + "/") { return url }

        let destination = uniqueDestination(for: url.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    /// A collision-free destination inside the library folder for `filename`:
    /// the plain name if free, otherwise " 2", " 3", … inserted before the
    /// extension. Shared by the copy-in (import) and move-in (download adopt)
    /// paths so both dedupe identically.
    private func uniqueDestination(for filename: String) -> URL {
        let fm = FileManager.default
        var destination = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: destination.path) else { return destination }
        let name = filename as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            destination = folder.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: destination.path)
        return destination
    }

    // MARK: Staging (in-flight downloads)

    /// A fresh hidden staging directory (`folder/.staging/<uuid>`) for one
    /// in-flight download. yt-dlp writes its intermediates here, where the
    /// watcher never sees them (`.skipsHiddenFiles` blocks descent into
    /// `.staging`), so no half-written row ever appears in the library. Returns
    /// nil if the directory can't be created.
    func makeStagingDir() -> URL? {
        let dir = folder.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Remove one download's staging directory and anything left in it.
    /// Idempotent — safe to call on every download exit path.
    func discardStaging(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Clear the whole `.staging` tree. Any survivor is from a download an
    /// earlier session didn't finish (crash/quit), so it's junk. Called once
    /// from `init` after the folder is resolved.
    func sweepOrphanedStaging() {
        let staging = folder.appendingPathComponent(".staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
    }

    /// Move a finished, staged file into the library and register it — the
    /// download counterpart to `bringIntoLibrary`'s copy. The fast path is an
    /// atomic rename when staging and library share a volume; if the library was
    /// relocated to another volume mid-download (`setFolder`), fall back to
    /// copy + delete. On any move-in failure the file is left in staging (swept
    /// later) and nil is returned. The finished row appears solely via the
    /// in-memory insert below (matching `add`), since the watcher stays silent.
    @discardableResult
    func adopt(_ stagedURL: URL) async -> Track? {
        let fm = FileManager.default
        let destination = uniqueDestination(for: stagedURL.lastPathComponent)
        do {
            try fm.moveItem(at: stagedURL, to: destination)
        } catch {
            // Cross-volume: clear any partial destination FIRST, then copy across
            // and unlink the source. Give up (leave for sweep) if the copy fails.
            do {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: stagedURL, to: destination)
                try? fm.removeItem(at: stagedURL)
            } catch {
                return nil
            }
        }
        let track = await Track.load(from: destination)
        if let existing = tracks.firstIndex(of: track) {
            tracks[existing] = track
        } else {
            tracks = arranged(tracks + [track])
        }
        return track
    }

    /// Switch the browse order. Persisted so it survives relaunch.
    func setView(_ newView: LibraryView) {
        guard newView != view else { return }
        view = newView
        prefs.libraryView = newView
        tracks = arranged(tracks)
    }

    /// Move a track's file to the Trash and drop it from the library.
    /// Only removes the track when the Trash actually succeeds — a file
    /// that's already missing on disk is treated as gone too. Returns
    /// `true` if the track was removed, `false` if it was kept because the
    /// Trash failed (in which case the caller should surface the error).
    @discardableResult
    func delete(_ track: Track) -> Bool {
        do {
            try FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
        } catch {
            guard !FileManager.default.fileExists(atPath: track.url.path) else {
                return false
            }
        }
        tracks.removeAll { $0 == track }
        return true
    }

    /// Change the library folder: move existing tracks there, then re-scan/watch.
    func setFolder(_ newFolder: URL) {
        guard newFolder.standardizedFileURL.path != folder.standardizedFileURL.path else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)

        for track in tracks {
            let destination = newFolder.appendingPathComponent(track.url.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: track.url, to: destination)
            }
        }

        folder = newFolder
        prefs.musicFolderBookmark = try? newFolder.bookmarkData()
        startWatching()
        Task { await scan() }
    }

    // MARK: Folder watching

    private func startWatching() {
        watcher?.cancel()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedFD = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
    }

    /// Debounced rescan — one pass after changes settle (e.g. copying many files).
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            followRename()
            await scan()
        }
    }

    /// The FD tracks the folder even if it's renamed while we run — read its
    /// current path back and update our URL + bookmark to match.
    private func followRename() {
        guard watchedFD >= 0, let url = Self.currentFolderURL(of: watchedFD) else { return }
        if url.standardizedFileURL.path != folder.standardizedFileURL.path {
            folder = url
            prefs.musicFolderBookmark = try? url.bookmarkData()
        }
    }

    private static func currentFolderURL(of fd: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map {
                URL(fileURLWithFileSystemRepresentation: $0, isDirectory: true, relativeTo: nil)
            }
        }
    }

    /// Order a freshly-scanned list by the active browse `view`.
    private func arranged(_ list: [Track]) -> [Track] {
        switch view {
        case .manual:
            return manuallyOrdered(list)
        case .recent:
            return list.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .alphabetical:
            return list.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .artist:
            return list.sorted(by: artistTrackOrder)
        }
    }

    /// Reconcile a list with the saved manual order: known files keep their saved
    /// position, new files sort in alphabetically at the end, and it's re-persisted.
    private func manuallyOrdered(_ list: [Track]) -> [Track] {
        let position = Dictionary(prefs.libraryOrder.enumerated().map { ($1, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let sorted = list.sorted { a, b in
            switch (position[a.url.path], position[b.url.path]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true                    // known before new files
            case (nil, _?): return false
            case (nil, nil):
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            }
        }
        prefs.libraryOrder = sorted.map(\.url.path)
        return sorted
    }

    /// Live reorder while a drag is in progress — moves the track with `path` to
    /// `index`. Mutates the in-memory order only; `commitOrder()` persists on drop.
    func reorder(path: String, toIndex index: Int) {
        guard let from = tracks.firstIndex(where: { $0.url.path == path }) else { return }
        var updated = tracks
        let item = updated.remove(at: from)
        updated.insert(item, at: min(max(index, 0), updated.count))
        if updated.map(\.url.path) != tracks.map(\.url.path) { tracks = updated }
    }

    /// Persist the current order once a drag finishes.
    func commitOrder() { prefs.libraryOrder = tracks.map(\.url.path) }

    /// Order tracks by artist → track number → title, so one artist's tracks read
    /// in a sensible order. Untagged fields sort last within their level.
    private var artistTrackOrder: (Track, Track) -> Bool {
        { a, b in
            let x = a.artist.lowercased(), y = b.artist.lowercased()
            if x != y { return x.isEmpty ? false : (y.isEmpty ? true : x < y) }
            let an = a.trackNumber ?? Int.max, bn = b.trackNumber ?? Int.max
            if an != bn { return an < bn }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }

    // MARK: Folder resolution & migration

    /// The user's chosen folder (resolved from a bookmark so it survives a
    /// rename/move), or the default `~/Documents/Sonar/`.
    static func resolveFolder(prefs: Preferences) -> URL {
        let fm = FileManager.default

        if let data = prefs.musicFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                if stale { prefs.musicFolderBookmark = try? url.bookmarkData() }
                return url
            }
        }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let folder = docs.appendingPathComponent("Sonar", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Bookmark even the default, so it too survives a rename.
        prefs.musicFolderBookmark = try? folder.bookmarkData()
        return folder
    }

    /// One-time move of tracks left in earlier storage locations into the
    /// current folder, so nothing is orphaned when the location changes.
    static func migrateLegacyFiles(into folder: URL) {
        let fm = FileManager.default
        var legacy: [URL] = []

        if let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first {
            legacy.append(music.appendingPathComponent("Sonar", isDirectory: true))
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { break }
            dir = dir.deletingLastPathComponent()
        }
        legacy.append(dir.appendingPathComponent("Music", isDirectory: true))

        for source in legacy where source.standardizedFileURL.path != folder.standardizedFileURL.path {
            guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items where audioExtensions.contains(item.pathExtension.lowercased()) {
                let destination = folder.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: destination.path) {
                    try? fm.moveItem(at: item, to: destination)
                }
            }
        }
    }
}
