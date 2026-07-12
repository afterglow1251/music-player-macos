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

    /// Make this text clickable to copy `value` to the clipboard. Adds no visible
    /// button — the affordance is a pointing-hand cursor and tooltip on hover, and
    /// a brief "Copied ✓" flash on click. Used for the now-playing title/artist so
    /// they can be lifted to the clipboard without cluttering the strip.
    func copyOnClick(_ value: String, help: String = "Click to copy", enabled: Bool = true) -> some View {
        modifier(CopyOnClick(value: value, help: help, enabled: enabled))
    }

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
            // Once a button opens a Menu, AppKit enters menu-tracking mode and
            // SwiftUI stops delivering hover-out events, so `show` would otherwise
            // stay true and the tooltip lingers under/around the open menu. Force
            // it closed as soon as any menu starts tracking (and on app resign-
            // active, for the same reason).
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                dismiss()
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

    private func dismiss() {
        delay?.cancel()
        show = false
    }
}

/// Puts `string` on the general pasteboard. Central so every copy affordance
/// (now-playing strip, row context menus) behaves identically.
@MainActor func copyToClipboard(_ string: String) {
    guard !string.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

/// Opens a URL in the user's default browser.
@MainActor func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}

/// Click-to-copy behaviour for a text view: a pointing-hand cursor + tooltip on
/// hover, and a brief "Copied ✓" pill on click. No resting chrome, so it stays
/// out of the way until the pointer lands on the text.
private struct CopyOnClick: ViewModifier {
    let value: String
    let help: String
    var enabled: Bool = true

    @State private var copied = false
    @State private var flashTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if enabled {
            copyable(content)
        } else {
            content
        }
    }

    private func copyable(_ content: Content) -> some View {
        content
            // On copy the label itself flashes to a "Copied ✓" pill in place, then
            // fades back — so the confirmation never lands on top of neighbouring
            // text. Hidden (not removed) so the row keeps its height/position.
            .opacity(copied ? 0 : 1)
            .contentShape(Rectangle())
            .onHover { inside in
                // Hint that the text is interactive without a visible button.
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture {
                guard !value.isEmpty else { return }
                copyToClipboard(value)
                flashTask?.cancel()
                withAnimation(.easeOut(duration: 0.12)) { copied = true }
                flashTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(850))
                    if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { copied = false } }
                }
            }
            .overlay(alignment: .leading) {
                if copied {
                    CopiedBadge()
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .help(help)
    }
}

/// The little "Copied ✓" pill that momentarily replaces the clicked text.
private struct CopiedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
            Text("Copied")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .fixedSize()
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

/// A quick horizontal wiggle — flags "this is already here" without words. Drive
/// `animatableData` 0→1 (one burst = `shakes` bumps) with an animation.
///
/// Rightward-only: the chip lives in a clipping horizontal ScrollView, so a
/// symmetric shake would clip its (input-aligned) left edge. Nudging only to the
/// right keeps that edge fixed and never crosses the clip.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = Double(animatableData) * .pi * 2 * Double(shakes)
        let dx = travel * CGFloat((1 - cos(phase)) / 2)   // smooth 0→travel→0, ≥ 0
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
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
    /// Whether to show the artist subtitle. Hidden when the list is already grouped
    /// by artist (the section header names the artist, so repeating it is noise).
    var showArtist: Bool = true
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
    /// Whether this track is favorited — drives the heart's filled/outline state.
    var isFavorite: Bool = false
    /// Toggle favorite. nil hides the heart entirely (e.g. contexts without a store).
    var onToggleFavorite: (() -> Void)? = nil
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
                if showArtist && !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Two overlaid layers, right-aligned, so the trailing edge is stable:
            //  • the duration, flush-right, shown at rest;
            //  • the hover controls — heart / trash / (drag, when reorderable) — as a
            //    single evenly-spaced group pinned to the far corner.
            // All three icons keep their slot at rest (only opacity changes), so the
            // heart never drifts, the spacing between the icons is uniform, and the
            // drag handle sits in the corner where the duration rests.
            ZStack(alignment: .trailing) {
                Text(durationText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: 6) {
                    if let onToggleFavorite {
                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 11))
                                .foregroundStyle(isFavorite ? Theme.favorite : .white.opacity(0.6))
                                .frame(width: 18, height: 20)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        // Visible at rest too, as a faint favorite indicator.
                        .opacity(isFavorite || hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.9))
                            .frame(width: 18, height: 20)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Delete (move to Trash)")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    if reorderID != nil {
                        DragDots()
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .named("reorder"))
                                    .onChanged { onReorderChanged($0.location.y) }
                                    .onEnded { _ in onReorderEnded() }
                            )
                            .help("Drag to reorder")
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                    }
                }
            }
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
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: isFavorite ? "heart.slash" : "heart")
                }
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
            Button { copyToClipboard(track.displayTitle) } label: {
                Label("Copy Title", systemImage: "doc.on.doc")
            }
            if !track.artist.isEmpty {
                Button { copyToClipboard(track.artist) } label: {
                    Label("Copy Artist", systemImage: "person")
                }
            }
            if let youtubeURL = track.youtubeURL {
                Button { openInBrowser(youtubeURL) } label: {
                    Label("Open on YouTube", systemImage: "arrow.up.forward.square")
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

/// Whether the currently-playing row is within the list's viewport. Emitted as a
/// Bool (not a frame) so the value only flips as the row crosses the viewport edge
/// — the parent's `onPreferenceChange` then fires rarely, not on every scroll
/// frame, avoiding the churn that reporting live frames would cause.
struct CurrentRowVisibleKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// A transparent AppKit overlay that owns *all* clicks on a small control and fires
/// `action` — including clicks in a `.nonactivatingPanel` (the menu-bar player),
/// which never becomes key from a plain button press. Used for the Mute button,
/// whose SwiftUI `Button` only fired after the volume `NSSlider` beside it (which
/// does take key) had been touched. Because this view always wins hit-testing, the
/// SwiftUI hover beneath it never fires either — so it reports its own hover state
/// via `onHover`, letting the caller drive the same grow-on-hover feedback the
/// neighbouring buttons get from `PressableButtonStyle`.
struct FirstMouseButton: NSViewRepresentable {
    let action: () -> Void
    var onHover: ((Bool) -> Void)? = nil
    func makeNSView(context: Context) -> NSView { Catcher(action: action, onHover: onHover) }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let catcher = nsView as? Catcher else { return }
        catcher.action = action
        catcher.onHover = onHover
    }

    private final class Catcher: NSView {
        var action: () -> Void
        var onHover: ((Bool) -> Void)?
        init(action: @escaping () -> Void, onHover: ((Bool) -> Void)?) {
            self.action = action; self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
        // Fire even on the click that merely activates the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action() }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}

/// Pins the enclosing scroll view to the thin overlay scroller. With a physical
/// mouse attached, AppKit's preferred style flips to legacy — the wide bar with
/// a permanent track — and SwiftUI's `.scrollIndicators` offers no way to keep
/// indicators visible *without* inheriting that. Attach as a `.background` of
/// the scroll view's **content** (not the ScrollView itself) so
/// `enclosingScrollView` resolves through the document-view hierarchy.
struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Enforcer() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Enforcer: NSView {
        // nonisolated(unsafe): only so the nonisolated deinit can hand the
        // token back to NotificationCenter (removeObserver is thread-safe).
        private nonisolated(unsafe) var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            // AppKit re-resolves the style when input devices change (mouse
            // plugged in / unplugged) — reapply each time it does.
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            // Defer a runloop: on insertion the enclosing scroll view isn't
            // wired up yet, and on a style-change notification AppKit's own
            // reset has to run first so it doesn't clobber ours.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let scrollView = self?.enclosingScrollView else { return }
                    scrollView.scrollerStyle = .overlay
                    scrollView.verticalScroller?.knobStyle = .light
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Scroll-wheel / trackpad-scroll to nudge a control's value. SwiftUI has no
/// `onScrollWheel` for arbitrary views, so while the cursor is over the view we
/// install a local scroll-wheel monitor and forward a normalized delta to
/// `onScroll` — one unit ≈ one wheel detent, **positive = physically scrolling up**
/// (add it to increase). Overlaying an NSView instead would swallow the slider's
/// own clicks (scroll delivery uses hit-testing), so hover-gating a monitor keeps
/// the underlying control fully interactive. The monitor consumes the event so a
/// parent ScrollView doesn't also move, and is torn down as soon as the cursor
/// leaves (or the view disappears).
struct ScrollToAdjust: ViewModifier {
    let onScroll: (Double) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside ? install() : remove() }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            var dy = event.scrollingDeltaY
            guard dy != 0 else { return event }
            // `scrollingDeltaY` already has the user's "natural scrolling" setting
            // baked in, so the same physical gesture reports opposite signs on a
            // trackpad (natural) vs a mouse wheel. Undo it via
            // `isDirectionInvertedFromDevice` so a physical upward scroll is always
            // positive — otherwise the control's direction flips per device.
            if event.isDirectionInvertedFromDevice { dy = -dy }
            // Trackpads report many small pixel deltas; a wheel reports a few lines.
            // Normalize both to "detents" so callers can use one step size.
            let units = event.hasPreciseScrollingDeltas ? dy / 8 : dy
            onScroll(Double(units))
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// See `ScrollToAdjust`. `onScroll` gets a normalized delta (≈ detents,
    /// positive = up); multiply by your control's per-detent step.
    func scrollToAdjust(_ onScroll: @escaping (Double) -> Void) -> some View {
        modifier(ScrollToAdjust(onScroll: onScroll))
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
                    // Only report frames while a drag is actually active. Reporting on
                    // every scroll frame otherwise churns this preference (and the
                    // parent's @State via onPreferenceChange), which showed up as
                    // scroll jank / high CPU even when nothing was being dragged.
                    Color.clear.preference(key: RowFrameKey.self,
                                           value: draggingID != nil ? [id: proxy.frame(in: .named("reorder"))] : [:])
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
            // Two lines — title over a muted artist — matching library/playlist rows.
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
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
