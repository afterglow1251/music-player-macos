import Foundation

/// One-time move of playlists and the manual library order from the single
/// global key they used to share onto per-folder keys (see `Preferences`).
///
/// The catch is that the pre-scoping data says nothing about which folder it
/// belongs to, and filing it under whatever folder happens to be selected at
/// launch would be wrong for exactly the users this fixes: someone who pointed
/// the library at a new folder is sitting on playlists built from the *old* one.
/// So each playlist is filed under the folder its own paths point into.
///
/// Nothing is deleted — the legacy keys stay behind untouched, so a bad guess
/// here is recoverable rather than destructive.
enum LibraryScopeMigration {
    /// Idempotent, and called from both `MusicLibrary` and `PlaylistStore` since
    /// either may be constructed first; whichever runs first does the work.
    static func run(prefs: Preferences, currentFolder: URL) {
        guard !prefs.folderScopedStateMigrated else { return }
        prefs.folderScopedStateMigrated = true

        // The manual order is always the current folder's: every scan rewrote it
        // in place, so it can only describe the folder in use right now.
        let order = prefs.legacyLibraryOrder
        if !order.isEmpty, prefs.libraryOrder(for: currentFolder).isEmpty {
            prefs.setLibraryOrder(order, for: currentFolder)
        }

        guard let data = prefs.legacyPlaylists,
              let lists = try? JSONDecoder().decode([Playlist].self, from: data),
              !lists.isEmpty else { return }

        var byFolder: [String: [Playlist]] = [:]
        for playlist in lists {
            let folder = folder(for: playlist, current: currentFolder)
            byFolder[folder.standardizedFileURL.path, default: []].append(playlist)
        }

        for (path, playlists) in byFolder {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard prefs.playlists(for: folder) == nil else { continue }
            prefs.setPlaylists(try? JSONEncoder().encode(playlists), for: folder)
        }
    }

    /// The folder a legacy playlist belongs to: the current one if any of its
    /// tracks live there, otherwise the deepest directory containing all of them
    /// — which for a playlist built out of one library is that library's folder.
    /// Falls back to the current folder when there's nothing to go on (an empty
    /// playlist, or paths with no shared root).
    static func folder(for playlist: Playlist, current: URL) -> URL {
        let paths = playlist.trackPaths
        guard !paths.isEmpty else { return current }

        let currentPath = current.standardizedFileURL.path
        if paths.contains(where: { $0.hasPrefix(currentPath + "/") }) { return current }

        guard let ancestor = commonAncestor(of: paths) else { return current }
        return ancestor
    }

    /// Deepest directory containing every one of `paths`. nil if they share no
    /// meaningful root (nothing above "/").
    private static func commonAncestor(of paths: [String]) -> URL? {
        let directories = paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL
                .deletingLastPathComponent().pathComponents
        }
        guard var shared = directories.first else { return nil }
        for components in directories.dropFirst() {
            let common = zip(shared, components).prefix { $0 == $1 }.map(\.0)
            shared = Array(common)
        }
        guard shared.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: shared), isDirectory: true)
    }
}
