import Testing
@testable import Sonar

/// Covers the documented behaviors of `PlaybackSequencer`: the deterministic
/// "what plays next" logic for auto-advance, manual ⏭ / ⏮, shuffle and the
/// three repeat modes.
struct PlaybackSequencerTests {

    let a = track("a")
    let b = track("b")
    let c = track("c")
    let notInList = track("z")

    // MARK: - activeScope

    @Test func activeScopeReturnsScopeWhenCurrentIsInIt() {
        let list = [a, b, c]
        #expect(PlaybackSequencer.activeScope(current: b, scope: list, library: [a]) == list)
    }

    @Test func activeScopeFallsBackToLibraryWhenCurrentNotInScope() {
        #expect(PlaybackSequencer.activeScope(current: notInList, scope: [a, b], library: [c]) == [c])
    }

    @Test func activeScopeFallsBackToLibraryWhenCurrentIsNil() {
        #expect(PlaybackSequencer.activeScope(current: nil, scope: [a, b], library: [c]) == [c])
    }

    // MARK: - nextDecision: sleep timer

    @Test func sleepUntilEndOfTrackWinsOverEverythingOnAutoAdvance() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: b, library: [a, b, c], scope: [a, b, c],
            queueFront: a, shuffle: true, repeatMode: .one, sleepUntilEndOfTrack: true)
        #expect(decision == .stopForSleep)
    }

    @Test func sleepFlagIsIgnoredOnManualSkip() {
        let decision = PlaybackSequencer.nextDecision(
            auto: false, current: a, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: true)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    // MARK: - nextDecision: repeat-one

    @Test func repeatOneReplaysCurrentTrackOnAutoAdvance() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: b, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .one, sleepUntilEndOfTrack: false)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    @Test func repeatOneDoesNotReplayOnManualSkip() {
        let decision = PlaybackSequencer.nextDecision(
            auto: false, current: a, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .one, sleepUntilEndOfTrack: false)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    @Test func repeatOneWinsOverAQueuedTrack() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: b, library: [a, b, c], scope: [a, b, c],
            queueFront: a, shuffle: false, repeatMode: .one, sleepUntilEndOfTrack: false)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    // MARK: - nextDecision: queue

    @Test func queuedTrackOverridesTheNormalOrder() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: a, library: [a, b, c], scope: [a, b, c],
            queueFront: c, shuffle: true, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(c, scope: [a, b, c], fromQueue: true))
    }

    @Test func queuedTrackWinsOnManualSkipToo() {
        let decision = PlaybackSequencer.nextDecision(
            auto: false, current: a, library: [a, b, c], scope: [a, b, c],
            queueFront: c, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(c, scope: [a, b, c], fromQueue: true))
    }

    /// A queued track plays inside the *current scope* (a playlist), not the whole
    /// library — the source survives the interruption.
    @Test func queuedTrackStaysInTheCurrentScope() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: a, library: [a, b, c, notInList], scope: [a, b],
            queueFront: notInList, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(notInList, scope: [a, b], fromQueue: true))
    }

    // MARK: - nextDecision: resume after the queue

    /// Once the queue drains, playback resumes the playlist from the anchor (the
    /// scope track we left), not from the off-scope queued track.
    @Test func resumesPlaylistFromTheAnchorAfterTheQueue() {
        // Current is the just-finished queued track, absent from the playlist scope.
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: notInList, library: [a, b, c, notInList], scope: [a, b, c],
            queueFront: nil, resumeAnchor: a, shuffle: false, repeatMode: .off,
            sleepUntilEndOfTrack: false)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    /// The anchor drives shuffle too — the next random draw stays inside the scope,
    /// excluding the anchor's index.
    @Test func resumeAnchorSeedsShuffleWithinTheScope() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: notInList, library: [a, b, c, notInList], scope: [a, b, c],
            queueFront: nil, resumeAnchor: b, shuffle: true, repeatMode: .off,
            sleepUntilEndOfTrack: false)
        #expect(decision == .playRandom(in: [a, b, c], excluding: 1, scope: [a, b, c]))
    }

    /// With no usable anchor (or one no longer in the scope), an off-scope current
    /// falls back to walking the library, as before.
    @Test func offScopeCurrentWithoutAnchorFallsBackToLibrary() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: notInList, library: [a, b, c, notInList], scope: [a, b],
            queueFront: nil, resumeAnchor: nil, shuffle: false, repeatMode: .off,
            sleepUntilEndOfTrack: false)
        // notInList is library index 3 → next is end-of-library with repeat off.
        #expect(decision == .stopAtEnd)
    }

    // MARK: - nextDecision: shuffle

    @Test func shuffleReturnsARandomDrawExcludingTheCurrentIndex() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: b, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: true, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .playRandom(in: [a, b, c], excluding: 1, scope: [a, b, c]))
    }

    // MARK: - nextDecision: normal order

    @Test func normalOrderStepsToTheNextTrack() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: a, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(b, scope: [a, b, c], fromQueue: false))
    }

    @Test func repeatAllWrapsToTheStartAtTheEnd() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: c, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .all, sleepUntilEndOfTrack: false)
        #expect(decision == .play(a, scope: [a, b, c], fromQueue: false))
    }

    @Test func autoAdvanceStopsAtTheEndWithoutRepeat() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: c, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .stopAtEnd)
    }

    @Test func manualSkipWrapsAroundAtTheEndWithoutRepeat() {
        let decision = PlaybackSequencer.nextDecision(
            auto: false, current: c, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(a, scope: [a, b, c], fromQueue: false))
    }

    @Test func currentNotInListPlaysTheFirstTrack() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: notInList, library: [a, b, c], scope: [a, b, c],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(a, scope: [a, b, c], fromQueue: false))
    }

    @Test func emptyListHasNothingToPlay() {
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: nil, library: [], scope: [],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .none)
    }

    // MARK: - Library folder switched mid-playback

    /// `PlayerController.libraryFolderChanged` clears the scope when the library is
    /// pointed at another folder, leaving the old folder's track playing on. This is
    /// the contract that makes that work: with no scope, the walk falls back to the
    /// library — the *new* folder — even though the current track isn't in it. So
    /// the song you're hearing finishes, and ⏭ lands you in the folder on screen
    /// rather than deeper into the one you just left.
    @Test func clearedScopeAdvancesIntoTheNewLibrary() {
        let newFolder = [a, b, c]
        let decision = PlaybackSequencer.nextDecision(
            auto: false, current: notInList, library: newFolder, scope: [],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(a, scope: newFolder, fromQueue: false))
    }

    /// Same on auto-advance: the track ends and the new folder takes over, rather
    /// than reporting "end of scope" and stopping.
    @Test func clearedScopeAutoAdvancesIntoTheNewLibrary() {
        let newFolder = [a, b, c]
        let decision = PlaybackSequencer.nextDecision(
            auto: true, current: notInList, library: newFolder, scope: [],
            queueFront: nil, shuffle: false, repeatMode: .off, sleepUntilEndOfTrack: false)
        #expect(decision == .play(a, scope: newFolder, fromQueue: false))
    }
}
