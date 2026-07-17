import Foundation

/// How the library is presented: a hand-arranged manual order, or one of three
/// browse orders.
enum LibraryView: String, CaseIterable {
    case manual       // hand-arranged, drag to reorder
    case recent       // newest additions first
    case alphabetical // by title, A–Z
    case artist       // by artist, A–Z, grouped

    var label: String {
        switch self {
        case .manual:       return "Manual"
        case .recent:       return "Recent"
        case .alphabetical: return "A–Z"
        case .artist:       return "Artist"
        }
    }

    var symbol: String {
        switch self {
        case .manual:       return "arrow.up.arrow.down"
        case .recent:       return "clock"
        case .alphabetical: return "textformat"
        case .artist:       return "person"
        }
    }
}

/// Typed wrapper over `UserDefaults`. One place owns every key **and** its type,
/// so a read and a write can never disagree, and a mistyped key is a compile
/// error rather than a silent runtime bug.
final class Preferences {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key: String {
        case volume, eqGains, eqEnabled, shuffle, repeatMode
        case themeName, albumTheme, lastTrack, lastPosition, musicFolderBookmark
        case libraryOrder, librarySort, playlists
        case favorites, favoritesFilter
        case folderScopedStateMigrated
    }

    // MARK: Folder-scoped state

    /// Playlists and the manual order describe *one library folder's* files, so
    /// they're keyed by that folder rather than stored once for the whole app.
    /// Globally-stored state broke both when the folder changed: playlists came up
    /// empty because every saved path resolved against the wrong folder, and the
    /// manual order was overwritten outright by the first scan of the new folder.
    /// Scoped, pointing the library elsewhere and back restores both intact.
    private func scopedKey(_ key: Key, _ folder: URL) -> String {
        "\(key.rawValue).\(folder.standardizedFileURL.path)"
    }

    /// Manual library order for `folder` — file paths in the order the user
    /// arranged them. New files not in this list are appended; missing ones are
    /// dropped on scan.
    func libraryOrder(for folder: URL) -> [String] {
        defaults.array(forKey: scopedKey(.libraryOrder, folder)) as? [String] ?? []
    }

    func setLibraryOrder(_ order: [String], for folder: URL) {
        defaults.set(order, forKey: scopedKey(.libraryOrder, folder))
    }

    /// JSON-encoded `[Playlist]` built out of `folder`'s files.
    func playlists(for folder: URL) -> Data? {
        defaults.data(forKey: scopedKey(.playlists, folder))
    }

    func setPlaylists(_ data: Data?, for folder: URL) {
        defaults.set(data, forKey: scopedKey(.playlists, folder))
    }

    /// Carry a folder's scoped state over when the folder itself is renamed or
    /// moved. The bookmark already follows the folder, so without this the state
    /// would be stranded under the old path's key — a rename would read as "my
    /// playlists vanished". Saved paths are re-pointed at the new location too,
    /// since they're absolute and would otherwise all dangle.
    func moveFolderScope(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        guard oldPath != newPath else { return }

        func repoint(_ path: String) -> String {
            path == oldPath || path.hasPrefix(oldPath + "/")
                ? newPath + path.dropFirst(oldPath.count)
                : path
        }

        let order = libraryOrder(for: old)
        if !order.isEmpty {
            setLibraryOrder(order.map(repoint), for: new)
            defaults.removeObject(forKey: scopedKey(.libraryOrder, old))
        }

        if let data = playlists(for: old) {
            var moved = data
            if var lists = try? JSONDecoder().decode([Playlist].self, from: data) {
                for i in lists.indices { lists[i].trackPaths = lists[i].trackPaths.map(repoint) }
                moved = (try? JSONEncoder().encode(lists)) ?? data
            }
            setPlaylists(moved, for: new)
            defaults.removeObject(forKey: scopedKey(.playlists, old))
        }
    }

    /// Whether the one-time move of globally-stored playlists and manual order
    /// onto per-folder keys has run. See `LibraryScopeMigration`.
    var folderScopedStateMigrated: Bool {
        get { defaults.bool(forKey: Key.folderScopedStateMigrated.rawValue) }
        set { defaults.set(newValue, forKey: Key.folderScopedStateMigrated.rawValue) }
    }

    /// Favorited tracks — file paths, the same "currency" as `libraryOrder` and
    /// playlists. Unordered in spirit (stored as an array only because
    /// UserDefaults has no Set); missing files are simply ignored on lookup.
    var favorites: [String] {
        get { defaults.array(forKey: Key.favorites.rawValue) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: Key.favorites.rawValue) }
    }

    /// Whether the library list is currently filtered to favorites only. Persisted
    /// so the filter survives relaunch, like the browse `libraryView`.
    var favoritesFilter: Bool {
        get { defaults.bool(forKey: Key.favoritesFilter.rawValue) }
        set { defaults.set(newValue, forKey: Key.favoritesFilter.rawValue) }
    }

    /// The pre-scoping global manual order. Read once by `LibraryScopeMigration`
    /// and never written again — live reads/writes go through `libraryOrder(for:)`.
    /// Left in place after migrating as a safety net, not as a fallback.
    var legacyLibraryOrder: [String] {
        defaults.array(forKey: Key.libraryOrder.rawValue) as? [String] ?? []
    }

    /// The library view — defaults to the hand-arranged manual order.
    var libraryView: LibraryView {
        get { defaults.string(forKey: Key.librarySort.rawValue).flatMap(LibraryView.init) ?? .manual }
        set { defaults.set(newValue.rawValue, forKey: Key.librarySort.rawValue) }
    }

    /// The pre-scoping global playlists — migration's input only, like
    /// `legacyLibraryOrder`. Live access is `playlists(for:)`.
    var legacyPlaylists: Data? {
        defaults.data(forKey: Key.playlists.rawValue)
    }

    /// Bookmark to the music folder — survives the folder being renamed/moved
    /// (a plain path string would not). nil = use the default location.
    var musicFolderBookmark: Data? {
        get { defaults.data(forKey: Key.musicFolderBookmark.rawValue) }
        set { defaults.set(newValue, forKey: Key.musicFolderBookmark.rawValue) }
    }

    var volume: Float? {
        get { defaults.object(forKey: Key.volume.rawValue) as? Float }
        set { defaults.set(newValue, forKey: Key.volume.rawValue) }
    }

    /// Stored as `[Double]` (UserDefaults has no Float array), exposed as `[Float]`.
    var eqGains: [Float]? {
        get { (defaults.array(forKey: Key.eqGains.rawValue) as? [Double])?.map(Float.init) }
        set { defaults.set(newValue?.map(Double.init), forKey: Key.eqGains.rawValue) }
    }

    var eqEnabled: Bool? {
        get { defaults.object(forKey: Key.eqEnabled.rawValue) as? Bool }
        set { defaults.set(newValue, forKey: Key.eqEnabled.rawValue) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle.rawValue) }
        set { defaults.set(newValue, forKey: Key.shuffle.rawValue) }
    }

    var repeatMode: RepeatMode {
        get { RepeatMode(rawValue: defaults.integer(forKey: Key.repeatMode.rawValue)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.repeatMode.rawValue) }
    }

    /// Theme is persisted by **name** (stable) rather than array index.
    var themeName: String? {
        get { defaults.string(forKey: Key.themeName.rawValue) }
        set { defaults.set(newValue, forKey: Key.themeName.rawValue) }
    }

    /// Whether the visualizer tiles are tinted from the current album cover.
    /// Optional so an unset value (fresh install) can default to on.
    var albumTheme: Bool? {
        get { defaults.object(forKey: Key.albumTheme.rawValue) as? Bool }
        set { defaults.set(newValue, forKey: Key.albumTheme.rawValue) }
    }

    var lastTrack: String? {
        get { defaults.string(forKey: Key.lastTrack.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastTrack.rawValue) }
    }

    var lastPosition: Double {
        get { defaults.double(forKey: Key.lastPosition.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastPosition.rawValue) }
    }
}
