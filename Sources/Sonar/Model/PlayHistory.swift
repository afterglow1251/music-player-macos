import Foundation

/// One track that actually played, stamped with the state the UI needs to show
/// it faithfully when you walk back to it. `sourceID` is the *context* the track
/// played under (nil = library) — for a queued interjection it's still the source
/// the queue was overlaid on, so the "Playing from …" label keeps naming it.
/// `fromQueue` drives the "· from queue" note.
struct PlayHistoryEntry: Equatable {
    var track: Track
    var sourceID: Playlist.ID?
    var fromQueue: Bool
}

/// A linear record of what actually played, with a cursor at the current track —
/// the spine of ⏮ / ⏭. Pure value type so the retrace logic is unit-testable
/// away from the audio engine and library singletons.
///
/// It subsumes the old shuffle "played order": both modes append here as tracks
/// play, and ⏮ / ⏭ just move the cursor, so retrace works the same whether the
/// order came from a playlist, the library, shuffle, or the queue.
struct PlayHistory: Equatable {
    private(set) var entries: [PlayHistoryEntry] = []
    /// Index of the current track; -1 when nothing has played yet.
    private(set) var cursor: Int = -1

    var current: PlayHistoryEntry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    /// At the newest track — the only place ⏭ / auto-advance generates a *new*
    /// track instead of replaying the recorded forward path.
    var atHead: Bool { cursor == entries.count - 1 }

    /// There's an earlier track to step back to.
    var canStepBack: Bool { cursor > 0 }

    /// Record a freshly-played track as the new head. If we were mid-history (the
    /// user had stepped back), the forward tail is dropped — playing something new
    /// forks a fresh path, exactly like a browser's history.
    mutating func push(_ entry: PlayHistoryEntry) {
        if cursor < entries.count - 1 { entries.removeSubrange((cursor + 1)...) }
        entries.append(entry)
        cursor = entries.count - 1
    }

    /// Step the cursor back one and return the now-current entry (nil at the start).
    mutating func stepBack() -> PlayHistoryEntry? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Step the cursor forward through the recorded path (nil already at the head).
    mutating func stepForward() -> PlayHistoryEntry? {
        guard cursor < entries.count - 1 else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Seed a single entry as the whole history — used to adopt a restored track
    /// so ⏮ / ⏭ and forward generation have a valid starting point.
    mutating func reset(to entry: PlayHistoryEntry) {
        entries = [entry]
        cursor = 0
    }

    /// Drop every entry matching `predicate` (e.g. a deleted track) and keep the
    /// cursor pointing at the same current entry where possible, otherwise clamp it
    /// into range.
    mutating func remove(where predicate: (PlayHistoryEntry) -> Bool) {
        guard !entries.isEmpty else { return }
        let removedBeforeCursor = entries[..<max(0, min(cursor, entries.count))].filter(predicate).count
        entries.removeAll(where: predicate)
        cursor = entries.isEmpty ? -1 : min(cursor - removedBeforeCursor, entries.count - 1)
        if cursor < 0, !entries.isEmpty { cursor = 0 }
    }
}
