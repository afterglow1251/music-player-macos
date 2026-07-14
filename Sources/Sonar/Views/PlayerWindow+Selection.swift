import SwiftUI
import AppKit

extension PlayerWindow {
    // MARK: Keyboard navigation

    /// The tracks the list currently shows, in on-screen order — what ↑/↓ walks.
    /// Mirrors the render: a selected playlist, the collapsible artist sections
    /// (skipping collapsed groups), or the flat/filtered library.
    var navigableTracks: [Track] {
        if selectedPlaylist != nil { return playlistTracks }
        if controller.library.view == .artist && searchText.isEmpty {
            return artistSections.flatMap { collapsedGroups.contains($0.id) ? [] : $0.tracks }
        }
        return filteredTracks
    }

    /// Move the keyboard cursor by `delta` (pure work in the reducer), then scroll
    /// to it — only keyboard nav scrolls; playback-follow doesn't.
    func moveSelection(by delta: Int) {
        if trackSelection.moveCursor(by: delta, in: navigableTracks, currentTrackID: controller.currentTrack?.id) {
            scrollToSelectionNonce += 1
        }
    }

    /// Play the row under the cursor, in the scope matching the current source.
    func playSelectedTrack() {
        guard let id = trackSelection.selectedTrackID,
              let track = navigableTracks.first(where: { $0.id == id }) else { return }
        if selectedPlaylist != nil {
            controller.play(track, in: playlistTracks)
        } else {
            controller.play(track, in: libraryPlaybackScope)
        }
    }

    /// A row click both plays the track and drops the cursor on it, so ↑/↓
    /// continue from there. Also collapses any multi-selection to this one row.
    private func selectAndPlay(_ track: Track, in scope: [Track]?) {
        trackSelection.pickForPlayback(track)
        controller.play(track, in: scope)
    }

    /// Route a row click by modifier: ⌘ toggles the row in/out of the selection
    /// (no playback), ⇧ selects the range from the anchor to the clicked row, and
    /// a plain click plays it (collapsing the selection to just that row). Keeps the
    /// Winamp-style click-to-play while layering standard macOS multi-select on top.
    /// The modifier read stays here (AppKit); the pure mutations live in the reducer.
    func handleRowTap(_ track: Track, in scope: [Track]?) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            trackSelection.toggleCommandClick(track, currentTrackID: controller.currentTrack?.id)
        } else if mods.contains(.shift) {
            trackSelection.extendShiftClick(to: track, in: navigableTracks)
        } else {
            selectAndPlay(track, in: scope)
        }
    }

    /// The selected tracks in on-screen order (empty when nothing is selected).
    private var selectedTracks: [Track] {
        trackSelection.selectedTracks(in: navigableTracks)
    }

    /// Select every track in the current view (⌘A).
    func selectAll() {
        trackSelection.selectAll(in: navigableTracks)
    }

    /// Delete the whole selection through the failure-aware bulk path, then clear.
    func deleteSelection() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            controller.delete(tracks)
            trackSelection.selection.removeAll()
        }
    }

    /// The bulk context menu for a row, or nil unless the row is part of a
    /// multi-selection (more than one row selected and this row among them).
    /// `playlist` non-nil adds a "Remove from Playlist" bulk action.
    func bulkRowMenu(for track: Track, inPlaylist playlist: Playlist? = nil) -> BulkRowMenu? {
        guard trackSelection.selection.contains(track.id), trackSelection.selection.count > 1 else { return nil }
        let tracks = selectedTracks
        let favs = tracks.map { controller.favorites.isFavorite($0.url.path) }
        return BulkRowMenu(
            count: tracks.count,
            allFavorited: favs.allSatisfy { $0 },
            anyFavorited: favs.contains(true),
            onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(tracks) } },
            onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(tracks) } },
            onFavorite: { withAnimation(.easeInOut(duration: 0.2)) { controller.setFavorite(tracks, to: true) } },
            onUnfavorite: { withAnimation(.easeInOut(duration: 0.2)) { controller.setFavorite(tracks, to: false) } },
            addToPlaylists: bulkPlaylistMenuItems(for: tracks),
            onNewPlaylistWithSelection: { createPlaylist(addingTracks: tracks, select: false) },
            onRemoveFromPlaylist: playlist.map { pl in
                { withAnimation(.easeInOut(duration: 0.2)) {
                    for t in tracks { controller.playlists.remove(path: t.url.path, from: pl.id) }
                    trackSelection.selection.removeAll()
                } }
            },
            onDelete: { deleteSelection() }
        )
    }

    /// "Add to Playlist" entries whose action adds ALL selected tracks at once.
    private func bulkPlaylistMenuItems(for tracks: [Track]) -> [PlaylistMenuItem] {
        controller.playlists.playlists.map { playlist in
            PlaylistMenuItem(id: playlist.id, name: playlist.name, contains: false) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    for t in tracks { _ = controller.playlists.add(path: t.url.path, to: playlist.id) }
                }
            }
        }
    }

    /// Floating bar of bulk actions, shown while 2+ rows are selected. Mirrors the
    /// right-click bulk menu as visible, one-tap buttons pinned to the card's bottom.
    @ViewBuilder var selectionBar: some View {
        if trackSelection.selection.count >= 2 {
            let tracks = selectedTracks
            let allFavorited = tracks.allSatisfy { controller.favorites.isFavorite($0.url.path) }
            HStack(spacing: 4) {
                Text("\(trackSelection.selection.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text("selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Divider().frame(height: 15).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4)

                // Icon shows STATE (filled pink when the whole selection is already
                // favorited), matching the row heart — the tooltip carries the action.
                selectionButton(allFavorited ? "heart.fill" : "heart",
                                help: allFavorited ? "Remove from Favorites" : "Add to Favorites",
                                tint: allFavorited ? Theme.favorite : .white.opacity(0.85)) {
                    withAnimation(.easeInOut(duration: 0.2)) { controller.setFavorite(tracks, to: !allFavorited) }
                }
                selectionButton("text.append", help: "Add to Queue") {
                    withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(tracks) }
                }
                // Queue first, then the playlist pair (add / remove) side by side.
                Menu {
                    ForEach(bulkPlaylistMenuItems(for: tracks)) { item in
                        Button(item.name, action: item.add)
                    }
                    if !controller.playlists.playlists.isEmpty { Divider() }
                    Button("New Playlist…") { createPlaylist(addingTracks: tracks, select: false) }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(PressableButtonStyle()).menuIndicator(.hidden).fixedSize()
                .tooltip("Add to Playlist")
                // text.badge.minus pairs with the Add to Playlist badge above;
                // xmark is taken by Clear selection. Inside a playlist the quick
                // action removes the entries from the list — permanent delete stays
                // a Library-only action (mirrors the row's hover control) so a tap
                // here can't be mistaken for wiping the file.
                if let playlist = selectedPlaylist {
                    selectionButton("text.badge.minus", help: "Remove from Playlist") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            for t in tracks { controller.playlists.remove(path: t.url.path, from: playlist.id) }
                            trackSelection.selection.removeAll()
                        }
                    }
                } else {
                    selectionButton("trash", help: "Delete", tint: .red.opacity(0.9)) { deleteSelection() }
                }

                Divider().frame(height: 15).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4)
                selectionButton("xmark", help: "Clear selection", size: 11) {
                    withAnimation(.easeInOut(duration: 0.2)) { trackSelection.selection.removeAll() }
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
            .background(
                Capsule().fill(Color(white: 0.15))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            )
            .overlay(Capsule().stroke(.white.opacity(0.08)))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// A compact icon button for the selection bar (smaller than the transport's).
    private func selectionButton(_ symbol: String, help: String, size: CGFloat = 12.5,
                                 tint: Color = .white.opacity(0.85),
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(help)
    }
}
