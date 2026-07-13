import Foundation

/// The user's favorited tracks. A lighter twin of `PlaylistStore`: an unordered
/// set of file paths (the same "currency" as `libraryOrder` and playlists), plus
/// a single filter flag that the library list honours. Every mutation persists
/// immediately through `Preferences`.
///
/// The filter is intentionally orthogonal to the browse order (`LibraryView`): you
/// can view *favorites only* while still sorting them A–Z, by artist, and so on.
@MainActor
final class FavoritesStore: ObservableObject {
    /// Favorited file paths. A Set so membership checks (one per rendered row) are
    /// O(1); persisted as a plain array since UserDefaults has no Set type.
    @Published private(set) var paths: Set<String> = []

    /// When on, the library list shows only favorited tracks.
    @Published private(set) var filterActive: Bool = false

    private let prefs: Preferences

    /// `prefs` is injectable so tests can use an isolated UserDefaults suite.
    init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
        paths = Set(prefs.favorites)
        filterActive = prefs.favoritesFilter
    }

    func isFavorite(_ path: String) -> Bool { paths.contains(path) }

    /// Flip a track's favorite state and persist.
    func toggle(_ path: String) {
        if paths.contains(path) {
            paths.remove(path)
        } else {
            paths.insert(path)
        }
        prefs.favorites = Array(paths)
    }

    /// Favorite or unfavorite many paths at once, persisting a single time — the
    /// bulk counterpart to `toggle` (multi-select "Add/Remove from Favorites").
    func setFavorite(_ batch: Set<String>, to favorite: Bool) {
        guard !batch.isEmpty else { return }
        if favorite { paths.formUnion(batch) } else { paths.subtract(batch) }
        prefs.favorites = Array(paths)
    }

    /// Turn the "favorites only" filter on or off. Persisted so it survives relaunch.
    func setFilter(_ on: Bool) {
        guard on != filterActive else { return }
        filterActive = on
        prefs.favoritesFilter = on
    }
}
