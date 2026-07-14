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

    // MARK: - previousDecision

    @Test func previousOnAnEmptyListIsNone() {
        #expect(PlaybackSequencer.previousDecision(current: nil, activeScope: [], shuffle: false) == .none)
    }

    @Test func previousWhenCurrentIsNotInTheListIsNone() {
        #expect(PlaybackSequencer.previousDecision(current: notInList, activeScope: [a, b, c], shuffle: false) == .none)
    }

    @Test func previousShufflesToARandomDrawExcludingTheCurrentIndex() {
        let decision = PlaybackSequencer.previousDecision(current: b, activeScope: [a, b, c], shuffle: true)
        #expect(decision == .playRandom(in: [a, b, c], excluding: 1, scope: [a, b, c]))
    }

    @Test func previousStepsBackToTheEarlierTrack() {
        let decision = PlaybackSequencer.previousDecision(current: b, activeScope: [a, b, c], shuffle: false)
        #expect(decision == .play(a, scope: [a, b, c], fromQueue: false))
    }

    @Test func previousWrapsToTheLastTrackFromTheStart() {
        let decision = PlaybackSequencer.previousDecision(current: a, activeScope: [a, b, c], shuffle: false)
        #expect(decision == .play(c, scope: [a, b, c], fromQueue: false))
    }
}
