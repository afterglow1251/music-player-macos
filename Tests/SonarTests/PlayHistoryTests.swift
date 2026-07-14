import Testing
import Foundation
@testable import Sonar

/// Covers the retrace spine: push (with forward-tail truncation), step back /
/// forward, head detection, and deletion cleanup — the pure logic behind ⏮ / ⏭.
struct PlayHistoryTests {

    let a = track("a")
    let b = track("b")
    let c = track("c")

    private func entry(_ t: Track, from source: UUID? = nil, fromQueue: Bool = false) -> PlayHistoryEntry {
        PlayHistoryEntry(track: t, sourceID: source, fromQueue: fromQueue)
    }

    @Test func startsEmpty() {
        let h = PlayHistory()
        #expect(h.current == nil)
        #expect(!h.canStepBack)
    }

    @Test func pushRecordsAndAdvancesTheCursor() {
        var h = PlayHistory()
        h.push(entry(a))
        h.push(entry(b))
        #expect(h.current?.track == b)
        #expect(h.atHead)
        #expect(h.canStepBack)
    }

    @Test func stepBackAndForwardWalkTheRecordedPath() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b)); h.push(entry(c))
        #expect(h.stepBack()?.track == b)
        #expect(h.stepBack()?.track == a)
        #expect(h.stepBack() == nil)          // at the start
        #expect(h.current?.track == a)
        #expect(h.stepForward()?.track == b)
        #expect(h.stepForward()?.track == c)
        #expect(h.stepForward() == nil)        // at the head
        #expect(h.atHead)
    }

    @Test func atHeadIsFalseAfterSteppingBack() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b))
        _ = h.stepBack()
        #expect(!h.atHead)
    }

    /// Playing something new while stepped back forks a fresh path — the forward
    /// tail is discarded, exactly like browser history.
    @Test func pushMidHistoryTruncatesTheForwardTail() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b)); h.push(entry(c))
        _ = h.stepBack()                       // now at b
        h.push(entry(a))                       // fork
        #expect(h.current?.track == a)
        #expect(h.atHead)
        #expect(h.stepForward() == nil)        // c is gone
        #expect(h.stepBack()?.track == b)
        #expect(h.stepBack()?.track == a)
        #expect(h.stepBack() == nil)           // original a, b, then forked a
    }

    /// A queue interjection is a normal history entry that just carries the flag,
    /// so ⏮ retraces onto it and the label can show "· from queue".
    @Test func queuedEntriesRetraceLikeAnyOther() {
        let src = UUID()
        var h = PlayHistory()
        h.push(entry(a, from: src))                          // playlist track
        h.push(entry(b, from: src, fromQueue: true))         // queued interjection
        h.push(entry(c, from: src))                          // resumed playlist
        #expect(h.stepBack()?.fromQueue == true)             // back onto the queued track
        #expect(h.current?.sourceID == src)
        #expect(h.stepBack()?.fromQueue == false)            // back onto the playlist track
    }

    @Test func resetAdoptsASingleEntry() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b))
        h.reset(to: entry(c))
        #expect(h.current?.track == c)
        #expect(h.atHead)
        #expect(!h.canStepBack)
    }

    @Test func removeDropsMatchingEntriesAndKeepsTheCursorValid() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b)); h.push(entry(c))
        _ = h.stepBack()                       // at b (cursor 1)
        h.remove { $0.track == a }             // drop an earlier entry
        #expect(h.current?.track == b)         // still on b, cursor shifted down
        #expect(h.stepBack() == nil)           // a is gone → b is now the start
        #expect(h.stepForward()?.track == c)
    }

    @Test func removingTheCurrentEntryClampsTheCursor() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b)); h.push(entry(c))  // at c
        h.remove { $0.track == c }
        #expect(h.current?.track == b)         // clamped back to the new head
        #expect(h.atHead)
    }

    @Test func removingEverythingEmptiesTheHistory() {
        var h = PlayHistory()
        h.push(entry(a)); h.push(entry(b))
        h.remove { _ in true }
        #expect(h.current == nil)
        #expect(!h.canStepBack)
    }
}
