import SwiftUI

extension View {
    /// Strip a `List` row down to look like our custom rows: no separator, no
    /// background, tight insets — so a native (smoothly reorderable) List matches
    /// the hand-styled look.
    func plainListRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// A named, collapsible artist section in the library (the "Various" section
/// gathers every single-track artist so they don't each get their own header).
struct LibrarySection: Identifiable {
    let id: String        // artist name, or "Various"
    let tracks: [Track]
    let isVarious: Bool   // rows keep their own artist label in the Various bucket
}

/// One entry in a row's "Add to Playlist ▸" submenu. `contains` marks playlists
/// the track is already in (shown with a checkmark); `add` performs the insert.
struct PlaylistMenuItem: Identifiable {
    let id: UUID
    let name: String
    let contains: Bool
    let add: () -> Void
}

/// When a row is part of a multi-selection, its context menu swaps the single-track
/// actions for these, each operating on the whole selection. Non-nil only on a
/// selected row while more than one row is selected; otherwise the row shows its
/// normal single-track menu.
struct BulkRowMenu {
    let count: Int
    /// Whether every / any selected track is already favorited — decides which of
    /// "Add to Favorites" / "Remove from Favorites" to offer.
    let allFavorited: Bool
    let anyFavorited: Bool
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onFavorite: () -> Void
    let onUnfavorite: () -> Void
    /// Each entry adds ALL selected tracks to that playlist.
    let addToPlaylists: [PlaylistMenuItem]
    let onNewPlaylistWithSelection: (() -> Void)?
    /// Non-nil only inside a playlist view — removes the selection from it.
    let onRemoveFromPlaylist: (() -> Void)?
    let onDelete: () -> Void
}

