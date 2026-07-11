import SwiftUI

/// Status text whose trailing "…" animates as 1→2→3 dots, so an indeterminate
/// step (e.g. "Preparing…") looks alive rather than frozen.
struct AnimatedStatusText: View {
    let status: String

    var body: some View {
        if status.hasSuffix("…") {
            // "Loading" stays put; only the dots cycle inside a fixed-width slot.
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3 + 1
                HStack(spacing: 0) {
                    Text(status.dropLast())
                    Text(String(repeating: ".", count: dots))
                        .frame(width: 12, alignment: .leading)
                }
            }
        } else {
            Text(status)
        }
    }
}

/// A small, dark, rounded tooltip label — Spotify-style.
struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.16)))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
            .fixedSize()
    }
}

extension View {
    /// Show a tidy custom tooltip above this view on hover (replaces the slow,
    /// native yellow `.help` tooltip with a Spotify-style one).
    func tooltip(_ text: String) -> some View { modifier(TooltipModifier(text: text)) }

    /// Strip a `List` row down to look like our custom rows: no separator, no
    /// background, tight insets — so a native (smoothly reorderable) List matches
    /// the hand-styled look.
    func plainListRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    @State private var show = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                delay?.cancel()
                if hovering {
                    delay = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { show = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { show = false }
                }
            }
            .overlay(alignment: .top) {
                if show {
                    TooltipLabel(text: text)
                        .offset(y: -30)
                        .allowsHitTesting(false)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
    }
}

/// A button style that reacts to hover and press: it brightens and grows a touch
/// on hover, and dips down when pressed — small springy feedback for liveliness.
struct PressableButtonStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.10
    var pressScale: CGFloat = 0.90

    func makeBody(configuration: Configuration) -> some View {
        Reactive(configuration: configuration, hoverScale: hoverScale, pressScale: pressScale)
    }

    private struct Reactive: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        let pressScale: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(hovering ? 0.10 : 0)
                .scaleEffect(configuration.isPressed ? pressScale : (hovering ? hoverScale : 1.0))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
                .animation(.spring(response: 0.18, dampingFraction: 0.5), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A named group of tracks shown as a collapsible section in the library.
struct LibrarySection: Identifiable {
    let id: String        // artist name / playlist name
    let tracks: [Track]
}

/// One entry in a row's "Add to Playlist ▸" submenu. `contains` marks playlists
/// the track is already in (shown with a checkmark); `add` performs the insert.
struct PlaylistMenuItem: Identifiable {
    let id: UUID
    let name: String
    let contains: Bool
    let add: () -> Void
}

/// A 6-dot drag handle (2 columns × 3 rows), the affordance for reordering.
struct DragDots: View {
    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow { dot; dot }
            }
        }
    }
    private var dot: some View { Circle().frame(width: 2.5, height: 2.5) }
}

/// One row in the library list. Highlights on hover and when it's the current
/// track, so the playlist feels interactive.
struct TrackRowView: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let durationText: String
    let onTap: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void
    /// Whether the queue already has items. When empty, "Play Next" and "Add to
    /// Queue" would do the same thing, so only "Play Next" is shown.
    var queueHasItems: Bool = false
    /// When set, a drag handle appears on hover and the row accepts drops. nil
    /// disables reordering (e.g. while searching).
    /// Non-nil enables the drag handle. `isDragging` lifts this row while it's the
    /// one being dragged; the gesture callbacks report the cursor's y (in the
    /// "reorder" coordinate space) so the parent can reorder by pure math.
    var reorderID: String? = nil
    var isDragging: Bool = false
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    var onReorderEnded: () -> Void = {}
    /// "Add to Playlist ▸" submenu contents. Empty = the submenu is hidden.
    var addToPlaylists: [PlaylistMenuItem] = []
    /// "New Playlist…" action inside the add-to submenu; nil hides it.
    var onNewPlaylistWithTrack: (() -> Void)? = nil
    /// "Remove from Playlist" action — shown only when set (row is inside a
    /// playlist, not the main library).
    var onRemoveFromPlaylist: (() -> Void)? = nil
    private let accent = Theme.accent

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent && isPlaying ? "speaker.wave.2.fill" : "music.note")
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? accent : .white.opacity(0.4))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // On hover show a trash button; otherwise the duration. Both live in a
            // fixed-width slot so nothing shifts; the button scales around its own
            // (small, centered) frame so it grows in place instead of drifting.
            // Duration and the hover controls are both always in the layout (only
            // their opacity changes), so nothing structurally appears/moves during
            // a fast reorder — which was making the drag handle "fly" away.
            ZStack(alignment: .trailing) {
                Text(durationText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: 8) {
                    if reorderID != nil {
                        DragDots()
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 11, height: 18)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .named("reorder"))
                                    .onChanged { onReorderChanged($0.location.y) }
                                    .onEnded { _ in onReorderEnded() }
                            )
                            .help("Drag to reorder")
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.9))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Delete (move to Trash)")
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: reorderID == nil ? 44 : 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: isDragging ? .black.opacity(0.45) : .clear,
                radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Play", action: onTap)
            Button("Play Next", action: onPlayNext)
            if queueHasItems {
                Button("Add to Queue", action: onAddToQueue)
            }
            if !addToPlaylists.isEmpty || onNewPlaylistWithTrack != nil {
                Menu("Add to Playlist") {
                    ForEach(addToPlaylists) { item in
                        Button(action: item.add) {
                            if item.contains {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                    if let onNewPlaylistWithTrack {
                        if !addToPlaylists.isEmpty { Divider() }
                        Button("New Playlist…", action: onNewPlaylistWithTrack)
                    }
                }
            }
            Divider()
            if let onRemoveFromPlaylist {
                Button("Remove from Playlist", role: .destructive, action: onRemoveFromPlaylist)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        if isDragging { return Color(white: 0.16) }
        if isCurrent { return accent.opacity(0.16) }
        return hovering ? .white.opacity(0.07) : .clear
    }
}

/// Collects each reorderable row's frame (keyed by id) in the list's coordinate
/// space, so a drag can compute the target index from cursor position — no
/// hit-testing, no lag.
struct RowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Applied to a reorderable row: reports its frame, lifts it above the others
/// while dragging, and offsets it to follow the cursor (its slot's midY keeps it
/// glued to the finger as the rest shift).
struct ReorderDragModifier: ViewModifier {
    let id: String
    let draggingID: String?
    let cursorY: CGFloat
    let frames: [String: CGRect]
    /// When false (e.g. grouped view), do nothing — no frame reporting, so
    /// expanding a section doesn't churn preferences and flicker.
    var enabled: Bool = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(y: draggingID == id ? cursorY - (frames[id]?.midY ?? cursorY) : 0)
                .zIndex(draggingID == id ? 1 : 0)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: RowFrameKey.self,
                                           value: [id: proxy.frame(in: .named("reorder"))])
                })
        } else {
            content
        }
    }
}

/// One row in the "Up Next" queue — compact, numbered, with a remove button on hover.
struct QueueRowView: View {
    let track: Track
    let position: Int
    let onRemove: () -> Void
    var reorderID: String? = nil
    var isDragging: Bool = false
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    var onReorderEnded: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 16)
            // Winamp-style single line: muted "Artist — " prefix, then the
            // title. Built by concatenation so the "…" truncates the whole line
            // as one, rather than clipping artist and title independently.
            Group {
                if track.artist.isEmpty {
                    Text(track.displayTitle).foregroundColor(.white.opacity(0.85))
                } else {
                    Text(track.artist).foregroundColor(.white.opacity(0.45))
                        + Text("  —  ").foregroundColor(.white.opacity(0.3))
                        + Text(track.displayTitle).foregroundColor(.white.opacity(0.85))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if reorderID != nil {
                    DragDots()
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 11, height: 18)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .named("reorder"))
                                .onChanged { onReorderChanged($0.location.y) }
                                .onEnded { _ in onReorderEnded() }
                        )
                        .help("Drag to reorder")
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Remove from queue")
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .frame(width: reorderID == nil ? 24 : 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isDragging ? Color(white: 0.16) : (hovering ? Color.white.opacity(0.06) : .clear)))
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: isDragging ? .black.opacity(0.45) : .clear,
                radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Queue", role: .destructive, action: onRemove)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
