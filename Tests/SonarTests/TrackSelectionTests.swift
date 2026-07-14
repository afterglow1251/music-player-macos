import Testing
@testable import Sonar

/// Covers the `TrackSelection` reducer: plain tap, ⌘-toggle, ⇧-range (with its
/// anchor invariant), select-all, keyboard cursor stepping, and the
/// `selectedTracks(in:)` projection that `deleteSelection()` builds on.
struct TrackSelectionTests {

    let a = track("a")
    let b = track("b")
    let c = track("c")
    let d = track("d")
    var tracks: [Track] { [a, b, c, d] }

    // MARK: - selectedTracks(in:)

    @Test func selectedTracksProjectsInOnScreenOrder() {
        var sel = TrackSelection()
        sel.selection = [c.id, a.id]
        #expect(sel.selectedTracks(in: tracks) == [a, c])
    }

    @Test func selectedTracksIsEmptyWhenNothingSelected() {
        let sel = TrackSelection()
        #expect(sel.selectedTracks(in: tracks).isEmpty)
    }

    // MARK: - plain tap (pickForPlayback)

    @Test func plainTapSelectsJustThatTrackAndIsNotExplicit() {
        var sel = TrackSelection()
        sel.selection = [a.id, b.id]
        sel.selectionIsExplicit = true
        sel.pickForPlayback(c)
        #expect(sel.selectedTrackID == c.id)
        #expect(sel.lastClickedID == c.id)
        #expect(sel.selection == [c.id])
        #expect(sel.selectionIsExplicit == false)
    }

    // MARK: - ⌘-toggle-tap

    @Test func commandClickOnThePlayingTrackPromotesTheFollowHighlightWithoutRemovingIt() {
        var sel = TrackSelection()
        sel.selection = [b.id]           // playback-follow highlight
        sel.selectionIsExplicit = false
        sel.toggleCommandClick(b, currentTrackID: b.id)
        #expect(sel.selection == [b.id])
        #expect(sel.selectionIsExplicit == true)
        #expect(sel.selectedTrackID == b.id)
        #expect(sel.lastClickedID == b.id)
    }

    @Test func commandClickOnAnotherTrackWhileNotExplicitStartsAFreshSelection() {
        var sel = TrackSelection()
        sel.selection = [b.id]           // playback-follow highlight on b
        sel.selectionIsExplicit = false
        sel.toggleCommandClick(c, currentTrackID: b.id)
        #expect(sel.selection == [c.id])   // b does not tag along
        #expect(sel.selectionIsExplicit == true)
    }

    @Test func commandClickTogglesOffAnAlreadySelectedTrackWhenExplicit() {
        var sel = TrackSelection()
        sel.selection = [a.id, b.id]
        sel.selectionIsExplicit = true
        sel.toggleCommandClick(a, currentTrackID: nil)
        #expect(sel.selection == [b.id])
        #expect(sel.selectedTrackID == a.id)
        #expect(sel.lastClickedID == a.id)
    }

    @Test func commandClickTogglesOnAnUnselectedTrackWhenExplicit() {
        var sel = TrackSelection()
        sel.selection = [b.id]
        sel.selectionIsExplicit = true
        sel.toggleCommandClick(c, currentTrackID: nil)
        #expect(sel.selection == [b.id, c.id])
    }

    // MARK: - ⇧-click anchor invariant

    @Test func shiftClickRangesOutWhenExplicitAndAnchorIsStillSelected() {
        var sel = TrackSelection()
        sel.selection = [a.id]
        sel.lastClickedID = a.id
        sel.selectionIsExplicit = true
        sel.extendShiftClick(to: c, in: tracks)
        #expect(sel.selection == [a.id, b.id, c.id])
        #expect(sel.lastClickedID == c.id)
        #expect(sel.selectedTrackID == c.id)
    }

    @Test func shiftClickRangesOutInReverseWhenTheAnchorIsAfterTheClickedRow() {
        var sel = TrackSelection()
        sel.selection = [c.id]
        sel.lastClickedID = c.id
        sel.selectionIsExplicit = true
        sel.extendShiftClick(to: a, in: tracks)
        #expect(sel.selection == [a.id, b.id, c.id])
        #expect(sel.lastClickedID == a.id)   // the newest click becomes the anchor
    }

    @Test func shiftClickIsAPlainPickWhenTheAnchorIsNoLongerInTheSelection() {
        var sel = TrackSelection()
        sel.selection = [d.id]           // anchor "a" isn't part of this selection
        sel.lastClickedID = a.id
        sel.selectionIsExplicit = true
        sel.extendShiftClick(to: c, in: tracks)
        #expect(sel.selection == [c.id])
        #expect(sel.lastClickedID == c.id)
        #expect(sel.selectionIsExplicit == true)
    }

    @Test func shiftClickIsAPlainPickWhenTheSelectionIsOnlyThePlaybackFollowHighlight() {
        var sel = TrackSelection()
        sel.selection = [a.id]           // follow highlight, not a deliberate pick
        sel.lastClickedID = a.id
        sel.selectionIsExplicit = false
        sel.extendShiftClick(to: c, in: tracks)
        #expect(sel.selection == [c.id])
        #expect(sel.selectionIsExplicit == true)
    }

    @Test func shiftClickIsAPlainPickWhenThereIsNoAnchorYet() {
        var sel = TrackSelection()
        sel.selection = []
        sel.lastClickedID = nil
        sel.selectionIsExplicit = true
        sel.extendShiftClick(to: c, in: tracks)
        #expect(sel.selection == [c.id])
        #expect(sel.lastClickedID == c.id)
    }

    @Test func aPlainShiftPickSeedsTheAnchorForTheNextShiftClick() {
        var sel = TrackSelection()
        sel.selection = []
        sel.lastClickedID = nil
        sel.selectionIsExplicit = true
        sel.extendShiftClick(to: b, in: tracks)   // plain pick, seeds anchor at b
        sel.extendShiftClick(to: d, in: tracks)   // now ranges out from b to d
        #expect(sel.selection == [b.id, c.id, d.id])
    }

    // MARK: - selectAll

    @Test func selectAllSelectsEveryTrackExplicitly() {
        var sel = TrackSelection()
        sel.selectAll(in: tracks)
        #expect(sel.selection == Set(tracks.map(\.id)))
        #expect(sel.selectionIsExplicit == true)
    }

    @Test func selectAllOnAnEmptyListIsANoOp() {
        var sel = TrackSelection()
        sel.selection = [a.id]
        sel.selectAll(in: [])
        #expect(sel.selection == [a.id])
    }

    // MARK: - moveCursor (⬆/⬇ keyboard stepping + anchor seeding)

    @Test func moveCursorOnAnEmptyListReturnsFalseAndDoesNothing() {
        var sel = TrackSelection()
        let moved = sel.moveCursor(by: 1, in: [], currentTrackID: nil)
        #expect(moved == false)
        #expect(sel.selectedTrackID == nil)
    }

    @Test func moveCursorSeedsAtTheStartWhenNothingIsSelectedAndMovingForward() {
        var sel = TrackSelection()
        let moved = sel.moveCursor(by: 1, in: tracks, currentTrackID: nil)
        #expect(moved == true)
        #expect(sel.selectedTrackID == a.id)
        #expect(sel.lastClickedID == a.id)
        #expect(sel.selection == [a.id])
        #expect(sel.selectionIsExplicit == true)
    }

    @Test func moveCursorSeedsAtTheEndWhenNothingIsSelectedAndMovingBackward() {
        var sel = TrackSelection()
        let moved = sel.moveCursor(by: -1, in: tracks, currentTrackID: nil)
        #expect(moved == true)
        #expect(sel.selectedTrackID == d.id)
    }

    @Test func moveCursorSeedsAtThePlayingRowBeforeApplyingTheStep() {
        var sel = TrackSelection()
        let moved = sel.moveCursor(by: 1, in: tracks, currentTrackID: c.id)
        #expect(moved == true)
        #expect(sel.selectedTrackID == c.id)   // seeds on the playing row, doesn't step yet
    }

    @Test func moveCursorStepsFromAnExistingCursor() {
        var sel = TrackSelection()
        sel.selectedTrackID = b.id
        let moved = sel.moveCursor(by: 1, in: tracks, currentTrackID: nil)
        #expect(moved == true)
        #expect(sel.selectedTrackID == c.id)
    }

    @Test func moveCursorClampsAtTheStartInsteadOfWrapping() {
        var sel = TrackSelection()
        sel.selectedTrackID = a.id
        _ = sel.moveCursor(by: -1, in: tracks, currentTrackID: nil)
        #expect(sel.selectedTrackID == a.id)
    }

    @Test func moveCursorClampsAtTheEndInsteadOfWrapping() {
        var sel = TrackSelection()
        sel.selectedTrackID = d.id
        _ = sel.moveCursor(by: 1, in: tracks, currentTrackID: nil)
        #expect(sel.selectedTrackID == d.id)
    }

    @Test func moveCursorCollapsesAMultiSelectionToTheNewCursor() {
        var sel = TrackSelection()
        sel.selectedTrackID = a.id
        sel.selection = [a.id, b.id, c.id]
        _ = sel.moveCursor(by: 1, in: tracks, currentTrackID: nil)
        #expect(sel.selection == [b.id])
    }
}
