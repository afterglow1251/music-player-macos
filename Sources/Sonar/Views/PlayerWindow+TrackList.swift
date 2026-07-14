import SwiftUI
import AppKit

extension PlayerWindow {
    /// A zero-size marker placed behind the currently-playing row: it emits whether
    /// that row sits inside the list viewport (a Bool, so it only flips at the edge —
    /// see CurrentRowVisibleKey). Absent for non-current rows, so an off-screen
    /// current row (not rendered by the lazy stack) reads as not visible.
    @ViewBuilder
    private func currentRowMarker(for track: Track) -> some View {
        if track == controller.currentTrack {
            GeometryReader { geo in
                let f = geo.frame(in: .named("libScroll"))
                let visible = libViewportHeight > 0 && f.maxY > 0 && f.minY < libViewportHeight
                Color.clear.preference(key: CurrentRowVisibleKey.self,
                                       value: CurrentRowReport(source: selectedPlaylistID, visible: visible))
            }
        }
    }

    /// Compact "UP NEXT" header shown at the top of the track list when queued.
    private var queueHeader: some View {
        HStack(spacing: 8) {
            Text("UP NEXT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.85))
            Text("\(controller.queue.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            Button {
                if let playlist = controller.saveQueueAsPlaylist() {
                    beginRename(id: playlist.id, current: playlist.name)
                }
            } label: {
                Text("Save")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
            .help("Save the queue as a playlist")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { controller.clearQueue() }
            } label: {
                Text("Clear")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
            .help("Clear the queue")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    func trackScroll(fixedHeight: CGFloat?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Queue lives at the top of the same list; hidden while searching.
                    if !controller.queue.isEmpty && !searchActive {
                        queueHeader
                        ForEach(Array(controller.queue.enumerated()), id: \.element.id) { index, item in
                            let qid = item.id.uuidString
                            QueueRowView(
                                track: item.track,
                                position: index + 1,
                                onRemove: {
                                    withAnimation(.easeInOut(duration: 0.2)) { controller.removeFromQueue(item) }
                                },
                                reorderID: qid,
                                isDragging: draggingID == qid,
                                dragActive: draggingID != nil,
                                onReorderChanged: { y in
                                    guard !autoScroller.sessionActive else { return }
                                    handleReorderDrag(id: qid, cursorY: y) { finishQueueReorder(id: qid) }
                                },
                                onReorderEnded: { finishQueueReorder(id: qid) }
                            )
                            .modifier(ReorderDragModifier(id: qid, draggingID: draggingID,
                                                          cursorY: dragCursorY, draggedFrame: draggedFrame,
                                                          frames: rowFrames,
                                                          sectionActive: dragIsQueueItem))
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)
                    }

                    // Head anchor mirroring the tail one: navigating to the first
                    // row scrolls here so its outline clears the top edge with
                    // breathing room, sitting just below any queue.
                    Color.clear.frame(height: 8).id(Self.listTopAnchorID)
                    if let playlist = selectedPlaylist {
                        if playlistTracks.isEmpty {
                            emptyMessage("This playlist is empty — right-click a library track to add it")
                        }
                        ForEach(playlistTracks) { track in
                            playlistRow(track, in: playlist)
                        }
                    } else if controller.library.tracks.isEmpty {
                        emptyMessage("Your library is empty — paste a URL or open a file")
                    } else {
                        if filteredTracks.isEmpty {
                            if controller.favorites.filterActive && searchText.isEmpty {
                                emptyMessage("No favorites yet — tap the heart on a track")
                            } else {
                                emptyMessage("No tracks match “\(searchText)”")
                            }
                        }
                        if controller.library.view == .artist && searchText.isEmpty {
                            // Collapsible per-artist sections; single-track artists are
                            // gathered into one "Various" group so there's no header wall.
                            ForEach(artistSections) { section in
                                groupHeader(section)
                                if !collapsedGroups.contains(section.id) {
                                    ForEach(section.tracks) { track in
                                        libraryRow(track, showArtist: section.isVarious)
                                    }
                                }
                            }
                        } else {
                            // Flat list (Manual / Recent / A–Z, or while searching).
                            // Drag-to-reorder only in the hand-arranged Manual view, and
                            // not while filtered (search or favorites) — a subset can't be
                            // safely reordered back into the full manual order.
                            let canReorder = searchText.isEmpty && !controller.favorites.filterActive
                                && controller.library.view == .manual
                            ForEach(filteredTracks) { track in
                                libraryRow(track, reorderID: canReorder ? track.url.path : nil)
                            }
                        }
                    }
                    // Tail anchor: navigating to the last row scrolls to this
                    // instead, so the whole content end clears the card edge and the
                    // row's outline isn't cropped. Its height is the breathing gap.
                    Color.clear.frame(height: 8).id(Self.listBottomAnchorID)
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                // Baseline "current row not visible" report from this source's
                // layout. The row marker ORs its "visible" on top; with no marker
                // rendered (row filtered out or far off-screen in the lazy stack)
                // this still guarantees a report tagged with the current source.
                .background {
                    Color.clear.preference(key: CurrentRowVisibleKey.self,
                                           value: CurrentRowReport(source: selectedPlaylistID, visible: false))
                }
                .coordinateSpace(.named("reorder"))
                // The floating copy of the dragged row. Drawn as an overlay of
                // the scroll *content* (same origin as the "reorder" space), so
                // positioning it is pure content-space math — and unlike the
                // real row it isn't a lazy-stack item, so it can't be culled.
                .overlay(alignment: .topLeading) { dragGhost }
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                // Inside the ScrollView on purpose — see OverlayScrollerStyle.
                .background(OverlayScrollerStyle())
                .background(AutoScrollerCapture(scroller: autoScroller))
            }
            .coordinateSpace(.named("libScroll"))
            .frame(height: fixedHeight)
            .frame(maxHeight: fixedHeight == nil ? .infinity : nil)
            // Measure the viewport height so a row can tell whether it's on screen.
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { libViewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in libViewportHeight = h }
                }
            }
            // The pill state comes straight from the layout's own report — no
            // timers. The source tag rejects stale reports from the outgoing
            // list during a switch; the new list's report (guaranteed by the
            // baseline emitter, even off-screen → off-screen) then flips the
            // pill exactly when the new layout has spoken.
            .onPreferenceChange(CurrentRowVisibleKey.self) { report in
                guard let report, report.source == selectedPlaylistID else { return }
                if report.visible || !currentTrackInSource {
                    // Row on screen, or the playing track isn't in this list at all
                    // → no pill. Hide now and invalidate any pending "show".
                    pillShowToken += 1
                    showNowPlayingPill = false
                } else {
                    // Row reported off screen. Don't turn the pill on this instant:
                    // a source switch settles over a couple of layout passes (offset
                    // restore + the lazy stack materialising the current row's
                    // marker), and the baseline "not visible" often lands one pass
                    // before the marker's "visible" that will keep the pill hidden.
                    // Turning on immediately would flash the pill for that one frame.
                    // Defer the show by a runloop; a "visible" report arriving first
                    // bumps the token and cancels it. Genuine off-screen rows (no
                    // marker follows) still show, just imperceptibly later.
                    pillShowToken += 1
                    let token = pillShowToken
                    DispatchQueue.main.async {
                        guard pillShowToken == token, controller.currentTrack != nil else { return }
                        showNowPlayingPill = true
                    }
                }
            }
            // Keep the cursor on the playing track: when playback advances (auto-
            // advance, next/prev), move the selection to it so the outline never
            // lingers on the previous row. No scroll here — the "Now playing" pill
            // already offers a jump when the current track is off-screen.
            .onChange(of: controller.currentTrack) { _, track in
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
            // Switching source (LIBRARY ↔ playlist, or between playlists) reuses this
            // one ScrollView, so the outgoing list's scroll offset would otherwise
            // carry over — land you at the bottom of a list you just opened. Snap the
            // new source back to its top. Instant (no animation) to match the clean
            // header swap in selectSource; deferred a runloop so the new content has
            // laid out before we address its top anchor.
            .onChange(of: selectedPlaylistID) { oldID, newID in
                // goToCurrentTrack switches source only to then centre on the playing
                // track — don't fight it by restoring a remembered offset.
                if suppressTopResetOnce { suppressTopResetOnce = false; return }
                // All sources share this one ScrollView, so without help the outgoing
                // list's offset carries into the incoming one. Instead each source has
                // its own memory: selectSource stashed the outgoing offset (it must —
                // by the time this handler runs the content has already swapped and
                // the live offset may be clamped to the new list); here we restore
                // the incoming one (top for a never-visited source).
                guard let sv = autoScroller.scrollView else { return }
                let target = scrollMemory[newID] ?? 0
                // Invalidate any pending "jump to current track" from the outgoing
                // source: a Now-playing tap fires a deferred proxy.scrollTo(currentID),
                // and if the user switches source before it fires it would otherwise
                // resolve against THIS new list and scroll it to a stray spot (and
                // flash the pill).
                jumpGeneration += 1
                // The restorer applies the offset now and keeps re-applying as the
                // incoming LazyVStack grows its document over subsequent layout
                // passes — a single write here gets clamped against whatever height
                // the document happens to have mid-swap (deep library offsets always
                // lost that race and snapped to the top).
                scrollRestorer.restore(target, in: sv)
            }
            .onChange(of: scrollToCurrentNonce) { _, _ in
                guard let id = controller.currentTrack?.id else { return }
                scrollRestorer.cancel()   // a jump supersedes any in-flight restore
                jumpGeneration += 1
                let generation = jumpGeneration
                let source = selectedPlaylistID
                // Defer a runloop so anything we just cleared (search / filter) has
                // laid out, then center the current track. Instant, not animated: a
                // glide leaves a 0.3s window in which switching source would let the
                // scroll bleed into the new list. Bail if the source changed (or
                // another jump superseded us) before this ran.
                DispatchQueue.main.async {
                    guard jumpGeneration == generation, selectedPlaylistID == source else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Keep the keyboard cursor on screen — minimal scroll (nil anchor)
            // reveals a just-off-edge row without recentring the whole list.
            // Scroll only for keyboard navigation (nonce-driven), never when the
            // cursor merely follows a track change — that would yank the list.
            .onChange(of: scrollToSelectionNonce) { _, _ in
                scrollRestorer.cancel()   // keyboard nav supersedes an in-flight restore
                guard let id = selectedTrackID else { return }
                let tracks = navigableTracks
                if id == tracks.last?.id {
                    // Animate like a middle-row step so the scroller fades the same
                    // way at both edges; the completion re-snap covers lazy-layout
                    // undershoot, keeping the anchor's breathing room reliable.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(Self.listBottomAnchorID, anchor: .bottom)
                        } completion: {
                            proxy.scrollTo(Self.listBottomAnchorID, anchor: .bottom)
                        }
                    }
                } else if id == tracks.first?.id {
                    // Mirror the tail: animated step + completion re-snap to the
                    // head anchor so the first row reaches the true top.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(Self.listTopAnchorID, anchor: .top)
                        } completion: {
                            proxy.scrollTo(Self.listTopAnchorID, anchor: .top)
                        }
                    }
                } else {
                    // Middle rows: minimal scroll reveals a just-off-edge row.
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// The floating replica of the dragged row that follows the cursor. The real
    /// row hides while dragging: as a lazy-stack item it stops rendering once its
    /// slot scrolls off-screen no matter how far it's offset, so on long
    /// auto-scrolls the dragged track went invisible.
    @ViewBuilder private var dragGhost: some View {
        if let id = draggingID, let frame = draggedFrame {
            // The cursor may wander outside the list, but the ghost stays inside:
            // clamped to the content (first row top … last row bottom, `geo` is
            // the full scrollable content) and to the visible viewport (the clip
            // view's bounds), so it parks at the edge instead of escaping the
            // container. Purely visual — the drop index still follows the cursor.
            GeometryReader { geo in
                let clip = autoScroller.scrollView?.contentView.bounds
                let minY = max(6, clip?.minY ?? -.infinity)
                let maxY = min(geo.size.height - 6, clip?.maxY ?? .infinity) - frame.height
                ghostRow(for: id)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX,
                            y: min(max(dragCursorY - frame.height / 2, minY), max(minY, maxY)))
            }
            .allowsHitTesting(false)
        }
    }

    /// A non-interactive copy of the dragged row, styled as lifted.
    @ViewBuilder private func ghostRow(for id: String) -> some View {
        if let uid = UUID(uuidString: id) {
            if let index = controller.queue.firstIndex(where: { $0.id == uid }) {
                QueueRowView(track: controller.queue[index].track,
                             position: index + 1,
                             onRemove: {},
                             reorderID: id,
                             isDragging: true)
            }
        } else {
            let tracks = selectedPlaylist != nil ? playlistTracks : filteredTracks
            if let track = tracks.first(where: { $0.url.path == id }) {
                TrackRowView(track: track,
                             isCurrent: controller.currentTrack == track,
                             isPlaying: engine.isPlaying,
                             isSelected: false,
                             selectionIsExplicit: false,
                             durationText: clockTimeString(track.duration),
                             onTap: {},
                             onPlayNext: {},
                             onAddToQueue: {},
                             onDelete: {},
                             reorderID: id,
                             isDragging: true,
                             isFavorite: controller.favorites.isFavorite(id),
                             onToggleFavorite: nil)
            }
        }
    }

    /// One library row. `reorderID` non-nil enables drag (Manual view only).
    /// `showArtist` is off inside a named artist section (the header already names it).
    private func libraryRow(_ track: Track, showArtist: Bool = true, reorderID: String? = nil) -> some View {
        let path = track.url.path
        return TrackRowView(
            track: track,
            isCurrent: controller.currentTrack == track,
            isPlaying: engine.isPlaying,
            isSelected: selection.contains(track.id),
            selectionIsExplicit: selectionIsExplicit,
            durationText: clockTimeString(track.duration),
            onTap: { handleRowTap(track, in: libraryPlaybackScope) },
            onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(track) } },
            onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(track) } },
            onDelete: { controller.delete(track) },
            showArtist: showArtist,
            queueHasItems: !controller.queue.isEmpty,
            reorderID: reorderID,
            isDragging: draggingID == path,
            dragActive: draggingID != nil,
            onReorderChanged: { y in
                guard !autoScroller.sessionActive else { return }
                handleReorderDrag(id: path, cursorY: y) { finishLibraryReorder(path: path) }
            },
            onReorderEnded: { finishLibraryReorder(path: path) },
            addToPlaylists: playlistMenuItems(for: track),
            onNewPlaylistWithTrack: { createPlaylist(addingTrack: track, select: false) },
            isFavorite: controller.favorites.isFavorite(path),
            onToggleFavorite: { withAnimation(.easeInOut(duration: 0.2)) { controller.toggleFavorite(track) } },
            bulk: bulkRowMenu(for: track)
        )
        .modifier(ReorderDragModifier(id: path, draggingID: draggingID,
                                      cursorY: dragCursorY, draggedFrame: draggedFrame,
                                      frames: rowFrames,
                                      enabled: reorderID != nil,
                                      sectionActive: !dragIsQueueItem))
        .background { currentRowMarker(for: track) }
    }

    /// One row inside a playlist. Plays through the playlist as its scope,
    /// reorders within the playlist, and offers "Remove from Playlist".
    private func playlistRow(_ track: Track, in playlist: Playlist) -> some View {
        let path = track.url.path
        let scope = playlistTracks
        return TrackRowView(
            track: track,
            isCurrent: controller.currentTrack == track,
            isPlaying: engine.isPlaying,
            isSelected: selection.contains(track.id),
            selectionIsExplicit: selectionIsExplicit,
            durationText: clockTimeString(track.duration),
            onTap: { handleRowTap(track, in: scope) },
            onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(track) } },
            onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(track) } },
            onDelete: { controller.delete(track) },
            queueHasItems: !controller.queue.isEmpty,
            reorderID: path,
            isDragging: draggingID == path,
            dragActive: draggingID != nil,
            onReorderChanged: { y in
                guard !autoScroller.sessionActive else { return }
                handleReorderDrag(id: path, cursorY: y) { finishPlaylistReorder(path: path, in: playlist) }
            },
            onReorderEnded: { finishPlaylistReorder(path: path, in: playlist) },
            onRemoveFromPlaylist: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controller.playlists.remove(path: path, from: playlist.id)
                }
            },
            isFavorite: controller.favorites.isFavorite(path),
            onToggleFavorite: { withAnimation(.easeInOut(duration: 0.2)) { controller.toggleFavorite(track) } },
            bulk: bulkRowMenu(for: track, inPlaylist: playlist)
        )
        .modifier(ReorderDragModifier(id: path, draggingID: draggingID,
                                      cursorY: dragCursorY, draggedFrame: draggedFrame,
                                      frames: rowFrames,
                                      sectionActive: !dragIsQueueItem))
        .background { currentRowMarker(for: track) }
    }

    private func groupHeader(_ section: LibrarySection) -> some View {
        let collapsed = collapsedGroups.contains(section.id)
        return HStack(spacing: 7) {
            // A soft rotating chevron — quiet, animates open/closed.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 11)
            // Section name in a soft accent (matches playlist headers) — colored, so
            // it never blends with the white track titles, but not shouty.
            Text(section.id)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.85))
                .lineLimit(1)
            Text("\(section.tracks.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            Button { controller.playGroup(section.tracks) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Play")
        }
        // Generous space above separates one section from the previous rows; snug
        // below so the header sits close to its own tracks.
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed { collapsedGroups.remove(section.id) } else { collapsedGroups.insert(section.id) }
            }
        }
        // Sit above the sibling rows so the play button's tooltip isn't covered by
        // the tracks drawn after it.
        .zIndex(1)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14).padding(.horizontal, 4)
    }
}
