import Foundation

/// A saved, hand-curated set of tracks. Stores plain file paths — the same
/// "currency" as `libraryOrder` — so a playlist is just a lightweight ordered
/// reference into the library, never a copy of the audio. Paths whose file has
/// left the folder are simply skipped when the playlist is resolved to tracks.
struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var trackPaths: [String] = []
}

/// Owns the user's playlists and persists them as JSON in `Preferences`. A twin
/// of `MusicLibrary`: the view observes it (re-published through the controller)
/// and every mutation saves immediately, except live drag-reorder which defers
/// to `commit()` so a drag doesn't hammer UserDefaults every frame.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let prefs: Preferences

    /// `prefs` is injectable so tests can use an isolated UserDefaults suite
    /// instead of touching the real one.
    init(prefs: Preferences = Preferences()) {
        self.prefs = prefs
        load()
    }

    // MARK: Mutation

    /// Create an empty playlist. A blank/whitespace name falls back to the next
    /// free "Playlist N".
    @discardableResult
    func create(name: String? = nil) -> Playlist {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playlist = Playlist(name: trimmed.isEmpty ? defaultName() : trimmed)
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ id: Playlist.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: id) else { return }
        playlists[i].name = trimmed
        save()
    }

    func delete(_ id: Playlist.ID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Append a track path if it isn't already there. Returns false on a duplicate.
    @discardableResult
    func add(path: String, to id: Playlist.ID) -> Bool {
        guard let i = index(of: id), !playlists[i].trackPaths.contains(path) else { return false }
        playlists[i].trackPaths.append(path)
        save()
        return true
    }

    func remove(path: String, from id: Playlist.ID) {
        guard let i = index(of: id) else { return }
        playlists[i].trackPaths.removeAll { $0 == path }
        save()
    }

    /// Live drag-reorder: move `path` to `index`. Mutates memory only; call
    /// `commit()` on drop to persist.
    func reorder(path: String, toIndex index: Int, in id: Playlist.ID) {
        guard let i = self.index(of: id),
              let from = playlists[i].trackPaths.firstIndex(of: path) else { return }
        var paths = playlists[i].trackPaths
        let item = paths.remove(at: from)
        paths.insert(item, at: min(max(index, 0), paths.count))
        if paths != playlists[i].trackPaths { playlists[i].trackPaths = paths }
    }

    /// Persist once a drag finishes.
    func commit(_ id: Playlist.ID) { save() }

    func contains(path: String, in id: Playlist.ID) -> Bool {
        guard let i = index(of: id) else { return false }
        return playlists[i].trackPaths.contains(path)
    }

    // MARK: Internals

    private func index(of id: Playlist.ID) -> Int? {
        playlists.firstIndex { $0.id == id }
    }

    /// Lowest "Playlist N" not already taken.
    private func defaultName() -> String {
        let existing = Set(playlists.map(\.name))
        var n = playlists.count + 1
        while existing.contains("Playlist \(n)") { n += 1 }
        return "Playlist \(n)"
    }

    private func load() {
        guard let data = prefs.playlists,
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    private func save() {
        prefs.playlists = try? JSONEncoder().encode(playlists)
    }
}
