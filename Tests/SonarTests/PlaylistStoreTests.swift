import XCTest
@testable import Sonar

@MainActor
final class PlaylistStoreTests: XCTestCase {

    /// A Preferences backed by an isolated, freshly-cleared UserDefaults suite,
    /// so tests never touch the real one and never leak into each other.
    private func freshPrefs() -> Preferences {
        let name = "SonarTests.Playlists"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults)
    }

    // MARK: Create / name

    func testCreateAssignsDefaultName() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        XCTAssertEqual(playlist.name, "Playlist 1")
        XCTAssertEqual(store.playlists.count, 1)
    }

    func testDefaultNamesDoNotCollide() {
        let store = PlaylistStore(prefs: freshPrefs())
        store.create()
        let second = store.create()
        XCTAssertEqual(second.name, "Playlist 2")
    }

    func testCreateWithBlankNameFallsBackToDefault() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create(name: "   ")
        XCTAssertEqual(playlist.name, "Playlist 1")
    }

    // MARK: Rename / delete

    func testRename() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        store.rename(playlist.id, to: "Workout")
        XCTAssertEqual(store.playlists.first?.name, "Workout")
    }

    func testBlankRenameIsIgnored() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create(name: "Keep")
        store.rename(playlist.id, to: "  ")
        XCTAssertEqual(store.playlists.first?.name, "Keep")
    }

    func testDelete() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        store.delete(playlist.id)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    // MARK: Tracks

    func testAddTrack() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        XCTAssertTrue(store.add(path: "/a.mp3", to: playlist.id))
        XCTAssertEqual(store.playlists.first?.trackPaths, ["/a.mp3"])
    }

    func testAddDuplicateIsRejected() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        XCTAssertTrue(store.add(path: "/a.mp3", to: playlist.id))
        XCTAssertFalse(store.add(path: "/a.mp3", to: playlist.id))
        XCTAssertEqual(store.playlists.first?.trackPaths.count, 1)
    }

    func testRemoveTrack() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        store.add(path: "/a.mp3", to: playlist.id)
        store.add(path: "/b.mp3", to: playlist.id)
        store.remove(path: "/a.mp3", from: playlist.id)
        XCTAssertEqual(store.playlists.first?.trackPaths, ["/b.mp3"])
    }

    func testContains() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        store.add(path: "/a.mp3", to: playlist.id)
        XCTAssertTrue(store.contains(path: "/a.mp3", in: playlist.id))
        XCTAssertFalse(store.contains(path: "/x.mp3", in: playlist.id))
    }

    // MARK: Reorder

    func testReorderMovesTrack() {
        let store = PlaylistStore(prefs: freshPrefs())
        let playlist = store.create()
        for p in ["/a.mp3", "/b.mp3", "/c.mp3"] { store.add(path: p, to: playlist.id) }
        store.reorder(path: "/c.mp3", toIndex: 0, in: playlist.id)
        XCTAssertEqual(store.playlists.first?.trackPaths, ["/c.mp3", "/a.mp3", "/b.mp3"])
    }

    // MARK: Persistence

    func testPersistsAcrossInstances() {
        let prefs = freshPrefs()
        let store = PlaylistStore(prefs: prefs)
        let playlist = store.create(name: "Mix")
        store.add(path: "/a.mp3", to: playlist.id)

        let reloaded = PlaylistStore(prefs: prefs)   // new instance, same backing store
        XCTAssertEqual(reloaded.playlists.count, 1)
        XCTAssertEqual(reloaded.playlists.first?.name, "Mix")
        XCTAssertEqual(reloaded.playlists.first?.trackPaths, ["/a.mp3"])
    }
}
