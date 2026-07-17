import Testing
import Foundation
@testable import Sonar

/// Covers per-folder scoping of playlists and manual order: pointing the library
/// at another folder must park the old folder's state rather than resolve it
/// against the wrong files (playlists reading as empty) or overwrite it (the
/// manual order being rebuilt from the new folder's scan).
struct LibraryScopeTests {

    /// Each test gets its own defaults suite, so nothing here touches the real
    /// app's state and tests can't leak into each other.
    private func preferences() -> (Preferences, UserDefaults) {
        let name = "SonarTests.Scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (Preferences(defaults), defaults)
    }

    private let old = URL(fileURLWithPath: "/Music/test1", isDirectory: true)
    private let new = URL(fileURLWithPath: "/Music/test2", isDirectory: true)

    private func store(_ prefs: Preferences, _ playlists: [Playlist], in folder: URL) {
        prefs.setPlaylists(try! JSONEncoder().encode(playlists), for: folder)
    }

    private func read(_ prefs: Preferences, in folder: URL) -> [Playlist] {
        prefs.playlists(for: folder).map { try! JSONDecoder().decode([Playlist].self, from: $0) } ?? []
    }

    // MARK: Scoping

    @Test func playlistsAreKeptPerFolder() {
        let (prefs, _) = preferences()
        store(prefs, [Playlist(name: "Mix", trackPaths: ["/Music/test1/a.mp3"])], in: old)

        #expect(read(prefs, in: new).isEmpty)
        #expect(read(prefs, in: old).first?.name == "Mix")
    }

    @Test func manualOrderIsKeptPerFolder() {
        let (prefs, _) = preferences()
        prefs.setLibraryOrder(["/Music/test1/a.mp3"], for: old)
        prefs.setLibraryOrder(["/Music/test2/z.mp3"], for: new)

        // The bug this fixes: a scan of test2 used to overwrite test1's order.
        #expect(prefs.libraryOrder(for: old) == ["/Music/test1/a.mp3"])
        #expect(prefs.libraryOrder(for: new) == ["/Music/test2/z.mp3"])
    }

    /// The reported symptom, end to end: build playlists against one folder,
    /// switch away (they go quiet), switch back (they return intact).
    @MainActor
    @Test func switchingFolderAndBackRestoresPlaylists() {
        let (prefs, _) = preferences()
        prefs.musicFolderBookmark = nil
        store(prefs, [Playlist(name: "Road trip", trackPaths: ["/Music/test1/a.mp3"])], in: old)

        let store = PlaylistStore(prefs: prefs)
        store.setFolder(old)
        #expect(store.playlists.map(\.name) == ["Road trip"])

        store.setFolder(new)
        #expect(store.playlists.isEmpty)

        store.setFolder(old)
        #expect(store.playlists.map(\.name) == ["Road trip"])
        #expect(store.playlists.first?.trackPaths == ["/Music/test1/a.mp3"])
    }

    /// A playlist made while pointed at test2 must not bleed into test1.
    @MainActor
    @Test func newPlaylistBelongsOnlyToItsFolder() {
        let (prefs, _) = preferences()
        prefs.musicFolderBookmark = nil
        store(prefs, [Playlist(name: "Old", trackPaths: [])], in: old)

        let store = PlaylistStore(prefs: prefs)
        store.setFolder(new)
        store.create(name: "Fresh")

        #expect(read(prefs, in: new).map(\.name) == ["Fresh"])
        #expect(read(prefs, in: old).map(\.name) == ["Old"])
    }

    // MARK: Rename

    @Test func renamingAFolderCarriesItsStateAndRepointsPaths() {
        let (prefs, _) = preferences()
        store(prefs, [Playlist(name: "Mix", trackPaths: ["/Music/test1/a.mp3",
                                                         "/Music/test1/sub/b.mp3",
                                                         "/Elsewhere/c.mp3"])], in: old)
        prefs.setLibraryOrder(["/Music/test1/a.mp3"], for: old)

        prefs.moveFolderScope(from: old, to: new)

        #expect(read(prefs, in: old).isEmpty)
        #expect(prefs.libraryOrder(for: old).isEmpty)
        #expect(prefs.libraryOrder(for: new) == ["/Music/test2/a.mp3"])
        // Paths inside the renamed folder follow it; one outside is left alone.
        #expect(read(prefs, in: new).first?.trackPaths == ["/Music/test2/a.mp3",
                                                           "/Music/test2/sub/b.mp3",
                                                           "/Elsewhere/c.mp3"])
    }

    // MARK: Migration off the old global keys

    /// The real-world case: the user built playlists in test1, then switched the
    /// library to test2 and launched this build. Filing those playlists under the
    /// current folder would strand them — they belong to test1, where their files
    /// are, and must reappear on switching back.
    @Test func migrationFilesPlaylistsUnderTheFolderTheirTracksLiveIn() {
        let (prefs, defaults) = preferences()
        defaults.set(try! JSONEncoder().encode([
            Playlist(name: "Road trip", trackPaths: ["/Music/test1/a.mp3", "/Music/test1/b.mp3"]),
        ]), forKey: "playlists")

        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)

        #expect(read(prefs, in: new).isEmpty)
        #expect(read(prefs, in: old).map(\.name) == ["Road trip"])
    }

    /// Tracks nested in subfolders must still resolve to the library root, not to
    /// the deepest shared subdirectory.
    @Test func migrationPrefersTheCurrentFolderWhenTracksLiveThere() {
        let (prefs, defaults) = preferences()
        defaults.set(try! JSONEncoder().encode([
            Playlist(name: "Remixes", trackPaths: ["/Music/test2/Remixes/a.mp3",
                                                   "/Music/test2/Remixes/b.mp3"]),
        ]), forKey: "playlists")

        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)

        #expect(read(prefs, in: new).map(\.name) == ["Remixes"])
    }

    @Test func migrationKeepsAnEmptyPlaylistWithTheCurrentFolder() {
        let (prefs, defaults) = preferences()
        defaults.set(try! JSONEncoder().encode([Playlist(name: "Blank", trackPaths: [])]),
                     forKey: "playlists")

        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)

        #expect(read(prefs, in: new).map(\.name) == ["Blank"])
    }

    /// The manual order can only ever describe the folder in use, since every
    /// scan rewrote it in place.
    @Test func migrationFilesManualOrderUnderTheCurrentFolder() {
        let (prefs, defaults) = preferences()
        defaults.set(["/Music/test2/a.mp3"], forKey: "libraryOrder")

        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)

        #expect(prefs.libraryOrder(for: new) == ["/Music/test2/a.mp3"])
    }

    @Test func migrationRunsOnceAndLeavesTheLegacyDataInPlace() {
        let (prefs, defaults) = preferences()
        defaults.set(try! JSONEncoder().encode([
            Playlist(name: "Mix", trackPaths: ["/Music/test1/a.mp3"]),
        ]), forKey: "playlists")

        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)
        // A later edit must not be undone by a second pass.
        store(prefs, [], in: old)
        LibraryScopeMigration.run(prefs: prefs, currentFolder: new)

        #expect(read(prefs, in: old).isEmpty)
        #expect(prefs.legacyPlaylists != nil)   // kept as a safety net
    }
}
