import SwiftUI
import AppKit

extension PlayerWindow {
    // MARK: Drag reorder
    // The machinery (ghost/shift modifier, auto-scroll, event-monitor session,
    // frame preference) lives in ReorderDrag.swift — its file header explains
    // the architecture. Here is only the wiring into this window's lists:
    // live-drag state updates and the one model commit per drop.

    /// Whether the active drag is a queue item (queue rows key on UUID strings,
    /// list rows on file paths).
    var dragIsQueueItem: Bool {
        draggingID.flatMap { UUID(uuidString: $0) } != nil
    }

    /// Live drag tick, shared by all three lists. No model mutation happens
    /// here — the rows part around the cursor purely visually (see
    /// ReorderDragModifier) and the single model move lands on drop. Reordering
    /// the model live fed the shifting row frames straight back into the
    /// insertion math, which twitched the rows.
    func handleReorderDrag(id: String, cursorY: CGFloat, onEnd: @escaping () -> Void) {
        if draggingID != id { draggingID = id }
        dragCursorY = cursorY
        // Snapshot the slot frame once per drag (frames arrive a pass after
        // draggingID is set, hence the retry rather than a one-shot at start).
        if draggedFrame == nil, let frame = rowFrames[id] {
            draggedFrame = frame
            dragLog("start \(id) slot=\(frame)")
        }
        // The row's own gesture dies silently if the lazy stack culls the row
        // mid-drag, so a window event monitor takes over from the first tick —
        // including the mouse-up, which must fire the drop even then.
        autoScroller.beginSession(
            onDrag: { handleReorderDrag(id: id, cursorY: $0, onEnd: onEnd) },
            onUp: onEnd)
        autoScroller.onScroll = { handleReorderDrag(id: id, cursorY: $0, onEnd: onEnd) }
        autoScroller.update(cursorY: cursorY)
    }

    /// Insertion index for a drop: anchor on the row nearest the cursor that
    /// still has a known frame and derive the index from the data order. (The
    /// old "count every row above the cursor" undercounted on long drags — the
    /// lazy stack culls far-away rows, whose frames then stop reporting. The
    /// nearest row is on-screen by definition, so its frame is always known.)
    private func dropIndex(keys: [String]) -> Int? {
        var best: (index: Int, midY: CGFloat, distance: CGFloat)?
        for (index, key) in keys.enumerated() {
            guard let midY = rowFrames[key]?.midY else { continue }
            let distance = abs(midY - dragCursorY)
            if best == nil || distance < best!.distance { best = (index, midY, distance) }
        }
        guard let best else { return nil }
        return dragCursorY > best.midY ? best.index + 1 : best.index
    }

    /// Diagnostics for the drag machinery (Debug builds only) — enable with
    /// `defaults write com.sonar.player SonarDragDebug -bool YES`.
    private func dragLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SonarDragDebug") {
            print("[drag] \(message())")
        }
        #endif
    }

    /// Drop: move the dragged track to the slot the cursor is over and persist.
    /// (Manual view only.)
    func finishLibraryReorder(path: String) {
        // The event monitor's mouse-up and the gesture's onEnded can both land
        // here; the first one clears draggingID and the second is a no-op.
        guard draggingID == path else { return }
        autoScroller.stop()
        withAnimation(.easeInOut(duration: 0.18)) {
            if draggingID == path,
               let target = dropIndex(keys: filteredTracks.filter { $0.url.path != path }.map(\.url.path)) {
                dragLog("library drop \(path) → \(target) (\(rowFrames.count) frames known)")
                controller.library.reorder(path: path, toIndex: target)
            }
            draggingID = nil
            draggedFrame = nil
        }
        controller.library.commitOrder()
    }

    /// Drop within a playlist — same math against the playlist's rows.
    func finishPlaylistReorder(path: String, in playlist: Playlist) {
        guard draggingID == path else { return }
        autoScroller.stop()
        withAnimation(.easeInOut(duration: 0.18)) {
            if draggingID == path,
               let target = dropIndex(keys: playlistTracks.filter { $0.url.path != path }.map(\.url.path)) {
                dragLog("playlist drop \(path) → \(target) (\(rowFrames.count) frames known)")
                controller.playlists.reorder(path: path, toIndex: target, in: playlist.id)
            }
            draggingID = nil
            draggedFrame = nil
        }
        controller.playlists.commit(playlist.id)
    }

    /// Drop within the queue.
    func finishQueueReorder(id: String) {
        guard draggingID == id else { return }
        autoScroller.stop()
        withAnimation(.easeInOut(duration: 0.18)) {
            if draggingID == id, let uid = UUID(uuidString: id),
               let target = dropIndex(keys: controller.queue.filter { $0.id.uuidString != id }.map(\.id.uuidString)) {
                dragLog("queue drop \(id) → \(target)")
                controller.reorderQueue(id: uid, toIndex: target)
            }
            draggingID = nil
            draggedFrame = nil
        }
    }
}
