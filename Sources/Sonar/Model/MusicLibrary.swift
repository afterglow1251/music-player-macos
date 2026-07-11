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
    /// Current ordering (manual drag order, or sorted by a track field).
    @Published private(set) var sort: LibrarySort

    private let prefs = Preferences()
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac"]

    // Folder watcher.
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var rescanTask: Task<Void, Never>?

    init() {
        folder = Self.resolveFolder(prefs: Preferences())
        sort = prefs.librarySort
        Self.migrateLegacyFiles(into: folder)
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
        let track = await Track.load(from: url)
        if let existing = tracks.firstIndex(of: track) {
            tracks[existing] = track
        } else {
            tracks = arranged(tracks + [track])
        }
        return track
    }

    /// Switch the ordering. `.manual` restores the saved hand-arranged order; the
    /// others sort the current tracks by a field. Persisted so it survives relaunch.
    func setSort(_ newSort: LibrarySort) {
        guard newSort != sort else { return }
        sort = newSort
        prefs.librarySort = newSort
        tracks = arranged(tracks)
    }

    // MARK: Manual order

    /// Reorder by index (SwiftUI `.onMove` semantics).
    func move(fromOffsets: IndexSet, toOffset: Int) {
        var updated = tracks
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        applyManual(updated)
    }

    private func applyManual(_ list: [Track]) {
        tracks = list
        prefs.libraryOrder = list.map(\.url.path)
        setManualSort()
    }

    /// Any hand reorder implies the manual order is now what the user wants back.
    private func setManualSort() {
        guard sort != .manual else { return }
        sort = .manual
        prefs.librarySort = .manual
    }

    /// Live reorder while a drag is in progress — moves the track with `path` to
    /// `index`. Cheap: mutates the in-memory order only; call `commitOrder()` on
    /// drop to persist (so we don't hammer UserDefaults every frame).
    func reorder(path: String, toIndex index: Int) {
        guard let from = tracks.firstIndex(where: { $0.url.path == path }) else { return }
        var updated = tracks
        let item = updated.remove(at: from)
        updated.insert(item, at: min(max(index, 0), updated.count))
        if updated.map(\.url.path) != tracks.map(\.url.path) { tracks = updated }
    }

    /// Persist the current order once a drag finishes.
    func commitOrder() {
        prefs.libraryOrder = tracks.map(\.url.path)
        setManualSort()
    }

    /// Move a track's file to the Trash and drop it from the library.
    func delete(_ track: Track) {
        try? FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
        tracks.removeAll { $0 == track }
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

    /// Order a freshly-scanned list by the active `sort`.
    private func arranged(_ list: [Track]) -> [Track] {
        switch sort {
        case .manual:    return manuallyOrdered(list)
        case .title:     return list.sorted { titleKey($0) < titleKey($1) }
        case .artist:    return list.sorted(by: artistTrackOrder)
        case .dateAdded: return list.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        }
    }

    /// Reconcile a list with the saved manual order: known files keep their saved
    /// position, new files sort in alphabetically at the end, and the merged order
    /// is persisted.
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

    private func titleKey(_ t: Track) -> String { t.displayTitle.lowercased() }

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
