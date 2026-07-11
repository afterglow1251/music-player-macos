import XCTest
@testable import Sonar

/// Characterization tests: pin the CURRENT search behaviour so the upcoming
/// performance refactor can't change results by accident.
final class FuzzySearchTests: XCTestCase {

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzySearch.score("", "anything"), 1)
    }

    func testExactSubstringScoresHigh() {
        let score = FuzzySearch.score("floyd", "Pink Floyd")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 0.8)
    }

    func testEarlierMatchScoresHigherThanLater() {
        let early = FuzzySearch.score("pink", "Pink Floyd")!
        let late = FuzzySearch.score("floyd", "Pink Floyd")!
        XCTAssertGreaterThan(early, late)
    }

    func testSubsequenceMatches() {
        // "pf" appears in order in "Pink Floyd" (abbreviation).
        XCTAssertNotNil(FuzzySearch.score("pf", "Pink Floyd"))
    }

    func testTypoIsTolerated() {
        // one transposed/wrong letter should still match via edit distance.
        XCTAssertNotNil(FuzzySearch.score("floid", "Floyd"))
    }

    func testDiacriticsAreFolded() {
        XCTAssertNotNil(FuzzySearch.score("beyonce", "Beyoncé"))
    }

    func testUnrelatedQueryDoesNotMatch() {
        XCTAssertNil(FuzzySearch.score("zzzzzz", "Pink Floyd"))
    }

    func testScoreAcrossFieldsTakesBest() {
        // matches artist field even if the title field doesn't.
        let score = FuzzySearch.score("floyd", in: ["Eclipse", "Pink Floyd"])
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 0.8)
    }

    func testSubstringBeatsSubsequenceRanking() {
        let substring = FuzzySearch.score("eclipse", "Eclipse")!
        let subsequence = FuzzySearch.score("ecl", "Electric Cafe Lounge")!
        XCTAssertGreaterThan(substring, subsequence)
    }
}
