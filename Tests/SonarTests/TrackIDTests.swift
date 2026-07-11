import XCTest
@testable import Sonar

/// Pins how the YouTube video id is parsed from URLs and file names — the basis
/// of duplicate detection.
final class TrackIDTests: XCTestCase {

    // MARK: youtubeID(from:) — parse straight from a URL string

    func testWatchURL() {
        XCTAssertEqual(Track.youtubeID(from: "https://www.youtube.com/watch?v=7BTMok_FU2E"), "7BTMok_FU2E")
    }

    func testWatchURLWithExtraParams() {
        let url = "https://www.youtube.com/watch?v=7BTMok_FU2E&list=RD6blrGrLbxo4&index=6"
        XCTAssertEqual(Track.youtubeID(from: url), "7BTMok_FU2E")
    }

    func testShortURL() {
        XCTAssertEqual(Track.youtubeID(from: "https://youtu.be/7BTMok_FU2E"), "7BTMok_FU2E")
    }

    func testShortURLWithTimestamp() {
        XCTAssertEqual(Track.youtubeID(from: "https://youtu.be/7BTMok_FU2E?t=42"), "7BTMok_FU2E")
    }

    func testShortsURL() {
        XCTAssertEqual(Track.youtubeID(from: "https://www.youtube.com/shorts/7BTMok_FU2E"), "7BTMok_FU2E")
    }

    func testEmbedURL() {
        XCTAssertEqual(Track.youtubeID(from: "https://www.youtube.com/embed/7BTMok_FU2E"), "7BTMok_FU2E")
    }

    func testIDWithHyphenAndUnderscore() {
        XCTAssertEqual(Track.youtubeID(from: "https://youtu.be/7-mFsGm1uvQ"), "7-mFsGm1uvQ")
    }

    func testPlaylistOnlyURLHasNoVideoID() {
        XCTAssertNil(Track.youtubeID(from: "https://www.youtube.com/playlist?list=RD6blrGrLbxo4"))
    }

    func testNonYouTubeURLReturnsNil() {
        XCTAssertNil(Track.youtubeID(from: "https://example.com/song.mp3"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(Track.youtubeID(from: "  https://youtu.be/7BTMok_FU2E  \n"), "7BTMok_FU2E")
    }

    // MARK: filenameVideoID — fallback from the "name [id]" suffix

    func testFilenameSuffixParsed() {
        let url = URL(fileURLWithPath: "/x/A Fire Inside Of Me [7BTMok_FU2E].mp3")
        XCTAssertEqual(Track.filenameVideoID(url), "7BTMok_FU2E")
    }

    func testFilenameWithoutSuffixIsNil() {
        let url = URL(fileURLWithPath: "/x/Do To Me.mp3")
        XCTAssertNil(Track.filenameVideoID(url))
    }

    func testFilenameSuffixMustBeAtEnd() {
        // brackets mid-name (not the id suffix) shouldn't match.
        let url = URL(fileURLWithPath: "/x/Track [remix] title.mp3")
        XCTAssertNil(Track.filenameVideoID(url))
    }
}
