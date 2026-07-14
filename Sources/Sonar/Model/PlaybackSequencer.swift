import Foundation

/// What to do when a track ends or the user hits ⏭ / ⏮. Pure data — the
/// controller turns it into engine calls; tests assert it directly.
enum PlaybackDecision: Equatable {
    /// Nothing to play (empty list, or current track not resolvable).
    case none
    /// Sleep timer "until end of track" fired — stop, don't advance.
    case stopForSleep
    /// Reached the end of the scope with repeat off (auto-advance only).
    case stopAtEnd
    /// Load `track`, walking `scope`. `fromQueue` means it came off the queue
    /// front (the controller consumes it and resets the scope to the library).
    case play(Track, scope: [Track], fromQueue: Bool)
    /// Shuffle: play a random track from `list` other than index `excluding`.
    /// The random draw stays in the controller, so this logic stays deterministic.
    case playRandom(in: [Track], excluding: Int, scope: [Track])
}

/// The heart of playback — which track comes next — isolated from the audio
/// engine, the library scan and downloads so it can be unit-tested. `next` (⏭ /
/// auto-advance) and the gapless preload share `nextDecision`, so the preloaded
/// track can never disagree with what actually plays.
enum PlaybackSequencer {

    /// The list next/previous walk: the active scope while it still holds the
    /// current track, otherwise the whole library.
    static func activeScope(current: Track?, scope: [Track], library: [Track]) -> [Track] {
        if let current, scope.contains(current) { return scope }
        return library
    }

    /// The next step when a track ends (`auto == true`) or the user hits ⏭.
    ///
    /// `resumeAnchor` is the last scope track played before the queue interjected:
    /// once the queue drains, the walk picks up from *there* so the playlist keeps
    /// going, instead of stranding you wherever the queued (usually off-scope)
    /// track happened to land.
    static func nextDecision(auto: Bool,
                             current: Track?,
                             library: [Track],
                             scope: [Track],
                             queueFront: Track?,
                             resumeAnchor: Track? = nil,
                             shuffle: Bool,
                             repeatMode: RepeatMode,
                             sleepUntilEndOfTrack: Bool) -> PlaybackDecision {
        // Sleep "until end of track" wins over everything (auto-advance only).
        if auto, sleepUntilEndOfTrack { return .stopForSleep }
        // Repeat-one replays the current track (auto-advance only).
        if auto, repeatMode == .one, let current {
            let list = activeScope(current: current, scope: scope, library: library)
            return .play(current, scope: list, fromQueue: false)
        }
        // The queue overrides the normal order but stays inside the current scope,
        // so the source (playlist / library) survives the interruption.
        if let queued = queueFront { return .play(queued, scope: scope, fromQueue: true) }

        // Walk reference: normally the current track, but if it has left the scope
        // (it was a queued interjection) resume from the anchor parked in the scope.
        let list: [Track]
        let reference: Track?
        if let current, scope.contains(current) {
            list = scope; reference = current
        } else if let anchor = resumeAnchor, scope.contains(anchor) {
            list = scope; reference = anchor
        } else {
            list = activeScope(current: current, scope: scope, library: library)
            reference = current
        }
        guard !list.isEmpty else { return .none }
        guard let index = list.firstIndex(where: { $0 == reference }) else {
            return .play(list[0], scope: list, fromQueue: false)
        }
        if shuffle { return .playRandom(in: list, excluding: index, scope: list) }

        let nextIndex = index + 1
        if nextIndex < list.count { return .play(list[nextIndex], scope: list, fromQueue: false) }
        if repeatMode == .all { return .play(list[0], scope: list, fromQueue: false) }
        if auto { return .stopAtEnd }              // reached the end
        return .play(list[0], scope: list, fromQueue: false)   // manual ⏭ wraps around
    }
}
