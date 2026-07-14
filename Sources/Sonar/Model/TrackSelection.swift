import Foundation

/// The pure keyboard/selection model for the track list: the ↑/↓ cursor, the
/// ⇧-click range anchor, the multi-selection set, and whether that selection was
/// a *deliberate* pick. A value-type reducer — its methods are pure mutations
/// over the navigated `[Track]` list passed in, with no controller, engine, or
/// SwiftUI dependency. The view holds one in `@State` (same invalidation
/// granularity as the old four `@State` vars) and does the side effects (play,
/// delete, scroll-nonce bumps) around these mutations.
struct TrackSelection {
    /// Keyboard cursor (also the ⇧-click range anchor).
    var selectedTrackID: Track.ID?
    /// The last row the user *deliberately* clicked (plain / ⌘ / ⇧) — the older of
    /// the "last two" picks. A ⇧-click selects the range between it and the newly
    /// clicked row. Set only by real clicks (and keyboard nav), never by
    /// playback-follow, so the currently-playing track never silently acts as a
    /// range end. Nil before any click.
    var lastClickedID: Track.ID?
    /// Multi-selection for bulk actions (⌘/⇧-click).
    var selection: Set<Track.ID> = []
    /// True when `selection` was made deliberately (⌘/⇧-click, ⌘A, arrow keys) as
    /// opposed to falling out of a click-to-play or playback-follow, which also set
    /// it. An explicit selection outlines even the playing row.
    var selectionIsExplicit = false

    /// The selected tracks in on-screen order (empty when nothing is selected).
    func selectedTracks(in tracks: [Track]) -> [Track] {
        tracks.filter { selection.contains($0.id) }
    }

    /// Move the keyboard cursor by `delta`, seeding at the playing row (if shown)
    /// or an end when nothing is selected yet. Returns whether the cursor moved
    /// (false only for an empty list) so the view knows to bump its scroll nonce.
    mutating func moveCursor(by delta: Int, in tracks: [Track], currentTrackID: Track.ID?) -> Bool {
        guard !tracks.isEmpty else { return false }
        let index: Int
        if let id = selectedTrackID, let i = tracks.firstIndex(where: { $0.id == id }) {
            index = min(max(i + delta, 0), tracks.count - 1)
        } else if let current = currentTrackID,
                  let i = tracks.firstIndex(where: { $0.id == current }) {
            index = i
        } else {
            index = delta > 0 ? 0 : tracks.count - 1
        }
        selectedTrackID = tracks[index].id
        lastClickedID = tracks[index].id   // keep the ⇧-click anchor on the keyboard cursor
        selection = [tracks[index].id]   // arrow keys collapse any multi-selection to the cursor
        selectionIsExplicit = true
        return true
    }

    /// A row click both plays the track and drops the cursor on it, so ↑/↓
    /// continue from there. Also collapses any multi-selection to this one row.
    /// (The view performs the actual playback after calling this.)
    mutating func pickForPlayback(_ track: Track) {
        selectedTrackID = track.id
        lastClickedID = track.id
        selection = [track.id]
        selectionIsExplicit = false   // side effect of playing, not a deliberate pick
    }

    /// ⌘-click toggles a row in/out of the selection (no playback).
    mutating func toggleCommandClick(_ track: Track, currentTrackID: Track.ID?) {
        if !selectionIsExplicit {
            // The current `selection` is just the playback-follow highlight, not
            // a deliberate pick. ⌘-clicking the playing track itself should
            // promote it to an explicit selection (rather than toggling it back
            // off) so it outlines. ⌘-clicking any other track starts a fresh
            // explicit selection with just that row — otherwise the playing
            // track would silently tag along and outline as if also picked.
            selection = track.id == currentTrackID ? selection.union([track.id]) : [track.id]
            selectionIsExplicit = true
        } else if selection.contains(track.id) {
            selection.remove(track.id)
        } else {
            selection.insert(track.id)
        }
        selectedTrackID = track.id   // the ⌘-click becomes the latest pick
        lastClickedID = track.id
    }

    /// ⇧-click selects the range from the anchor to the clicked row.
    mutating func extendShiftClick(to track: Track, in tracks: [Track]) {
        // ⇧-click extends a range only when there's a *live, deliberate*
        // selection to anchor to — i.e. the anchor row is still explicitly
        // selected right now. This is checked against live state, not a
        // sticky flag, so the moment the selection is empty (fresh view,
        // everything cleared, background-tapped away) or is merely the
        // playback-follow highlight (a played track isn't a deliberate
        // pick), this ⇧-click is a plain pick: it selects just this row and
        // seeds the anchor, so the *next* ⇧-click ranges out from here.
        if selectionIsExplicit,
           let anchor = lastClickedID,
           selection.contains(anchor),
           let a = tracks.firstIndex(where: { $0.id == anchor }),
           let b = tracks.firstIndex(where: { $0.id == track.id }) {
            let range = a <= b ? a...b : b...a
            selection = Set(tracks[range].map { $0.id })
        } else {
            selection = [track.id]
            selectionIsExplicit = true
        }
        lastClickedID = track.id      // this click is now the newest anchor
        selectedTrackID = track.id
    }

    /// Select every track in the current view (⌘A).
    mutating func selectAll(in tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        selection = Set(tracks.map { $0.id })
        selectionIsExplicit = true
    }

    /// Keep the cursor on the playing track: when playback advances (auto-advance,
    /// next/prev), move the selection to it so the outline never lingers on the
    /// previous row.
    mutating func followPlayback(to track: Track?) {
        selectedTrackID = track?.id
        // The row outline is driven by `selection`, so collapse a single
        // selection onto the new track to keep the border with playback.
        // An active multi-selection (bulk action in progress) is left
        // untouched so we don't wipe the user's in-progress pick.
        if selection.count <= 1 {
            selection = track.map { [$0.id] } ?? []
            selectionIsExplicit = false   // playback-follow, not a user pick
        }
    }
}
