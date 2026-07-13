import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main player window — a modern retro-skinned player: a big uncropped cover,
/// a blurred artwork backdrop, glassy panels, and the classic tile visualizer.
struct PlayerWindow: View {
    @StateObject private var controller = PlayerController.shared
    @State private var isFullscreen = false
    @State private var fsLeftHeight: CGFloat = 400   // measured left-column height (fullscreen)
    @State private var scrollToCurrentNonce = 0      // bump to scroll the list to the current track
    @State private var showNowPlayingPill = false    // "playing row is off-screen", from the list's layout report
    @State private var libViewportHeight: CGFloat = 0 // measured list viewport height
    @State private var selectedTrackID: Track.ID?    // keyboard cursor + range anchor for ⇧-click
    @State private var selection: Set<Track.ID> = [] // multi-selection for bulk actions (⌘/⇧-click)
    /// True when `selection` was made deliberately (⌘/⇧-click, ⌘A, arrow keys) as
    /// opposed to falling out of a click-to-play or playback-follow, which also set
    /// it. An explicit selection outlines even the playing row.
    @State private var selectionIsExplicit = false
    @State private var scrollToSelectionNonce = 0    // bump to scroll to the cursor (keyboard nav only)
    @State private var suppressTopResetOnce = false  // skip the next source-switch scroll restore (goToCurrentTrack centres instead)
    @State private var scrollMemory: [Playlist.ID?: CGFloat] = [:]  // per-source scroll offset, so each source reopens where you left it
    private static let listBottomAnchorID = "nav-list-bottom"  // tail scroll anchor for the last row
    private static let listTopAnchorID = "nav-list-top"        // head scroll anchor for the first row
    @State private var muteHovering = false           // mute button hover (driven by its AppKit catcher)
    @State private var visualizerMode: VisualizerMode = .spectrum
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var seekHoverX: CGFloat?   // cursor x over the position slider
    // Gesture-driven reorder, shared by library & queue (ids never collide:
    // library rows key on file path, queue rows on a UUID string).
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingID: String?
    @State private var dragCursorY: CGFloat = 0
    /// The dragged row's slot frame, snapshotted at drag start — sizes/places the
    /// floating ghost and anchors the shift math even after the lazy stack culls
    /// the row itself.
    @State private var draggedFrame: CGRect?
    /// Scrolls the list when a reorder drag nears the viewport edge, so long
    /// lists can be reordered past the visible rows.
    @State private var autoScroller = ReorderAutoScroller()
    // Collapsed artist sections (Artist view).
    @State private var collapsedGroups: Set<String> = []
    // Source switcher: nil = the whole library, otherwise the viewed playlist.
    @State private var selectedPlaylistID: Playlist.ID?
    @State private var renamingPlaylist = false
    @State private var renameText = ""
    @State private var renameTargetID: Playlist.ID?
    @State private var showSettings = false
    @State private var showLyrics = false
    @State private var searchText = ""
    @State private var searchActive = false
    @State private var searchResults: [Track] = []   // filled off-main by the debounced search task
    @State private var urlChips: [String] = []   // links queued via the ＋ button
    @State private var shakingChipURL: String?   // chip to shake when a dupe is re-added
    @State private var isDropTargeted = false
    /// Whether the pointer is over the now-playing title/artist strip — reveals the
    /// "open on YouTube" link there without leaving a button parked at rest.
    @State private var nowPlayingHover = false
    /// Decoded once per track (not per frame) so the breathing animation doesn't
    /// re-decode the artwork 30×/sec.
    @State private var artworkImage: NSImage?
    @FocusState private var urlFieldFocused: Bool
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var renameFieldFocused: Bool

    /// Accent — the signature green, used sparingly.
    private let accent = Theme.accent

    private let contentWidth: CGFloat = 460
    private let artHeight: CGFloat = 340

    private var engine: AudioEngine { controller.engine }

    var body: some View {
        Group {
            if isFullscreen {
                fullscreenContent
            } else {
                normalContent
            }
        }
        // Enable the native green fullscreen button / ⌃⌘F, and track its state so
        // we can swap in the immersive visualizer when the window goes fullscreen.
        .background(FullscreenEnabler())
        // Decode artwork here (not in normalContent) so the cover updates in
        // fullscreen too, where normalContent isn't in the tree.
        .onAppear { decodeArtwork(controller.currentTrack) }
        .onChange(of: controller.currentTrack) { _, track in decodeArtwork(track) }
        // Search runs here, not in `body`: debounce the keystrokes, then rank on a
        // background task so a big library never blocks the UI. Re-keys on every
        // searchText change (the previous task is cancelled automatically).
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }        // empty → filteredTracks uses the library directly
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let tracks = controller.library.tracks
            let ranked = await Task.detached { PlayerWindow.rank(query: query, tracks: tracks) }.value
            if Task.isCancelled { return }
            searchResults = ranked
        }
        // Also re-decode when only the artwork changes (same track, metadata just
        // finished loading after a download) — same-url tracks compare equal, so
        // the change above wouldn't fire.
        .onChange(of: controller.currentTrack?.artworkData) { _, _ in
            decodeArtwork(controller.currentTrack)
        }
        // Swap to the fullscreen layout at the *start* of the native animation
        // (will…, not did…), so the two-column layout and its blurred backdrop grow
        // together with the window — instead of the small windowed column floating
        // in a growing black void and then popping into place once the animation ends.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        // …and swap back to the windowed layout at the *start* of the exit animation
        // too, so the shrinking window never shows the two-column fullscreen layout
        // crammed (and cover-clipped) into a half-size frame. The normal single column
        // rides the shrink down instead.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            // Once windowed again, snap the frame to the fixed-width content's natural
            // size so there are no leftover black margins around it. `normalContent`
            // has been laid out for the whole shrink (swapped in at willExit), so its
            // fittingSize is already correct — no settling delay needed.
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                if let content = window.contentView {
                    let fit = content.fittingSize
                    if fit.width > 100, fit.height > 100 { window.setContentSize(fit) }
                }
            }
        }
    }

    private var normalContent: some View {
        VStack(spacing: 12) {
            heroSlot(width: contentWidth, height: artHeight)
            infoStrip
            visualizerStrip
            positionSlider
            transportRow
            utilityRow
            downloadBar
            librarySection
        }
        .padding(16)
        .frame(width: contentWidth + 32)
        // Click any empty (black) area to dismiss the URL field's cursor.
        .background(
            backdrop
                .contentShape(Rectangle())
                .onTapGesture { dismissFocus(); selection.removeAll() }
        )
        .overlay(alignment: .bottom) { bottomToasts }
        // Drag & drop audio files or a YouTube link onto the window.
        // Files & URLs only (not plain text) so an internal reorder drag doesn't
        // trigger the window's drop highlight.
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { handleDrop($0) }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 2).padding(4)
            }
        }
        // Escape: close the search if it's open, otherwise just drop the cursor.
        .onExitCommand {
            if searchActive {
                withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                searchText = ""
                searchFieldFocused = false
            } else if selection.count > 1 {
                selection = selectedTrackID.map { [$0] } ?? []   // collapse a multi-selection first
                selectionIsExplicit = false
            } else {
                dismissFocus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
        }
        // Remember playback position on quit (in addition to pause/track-change).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.saveOnQuit()
        }
        // Keyboard model (active only while no text field is focused, so fields
        // keep their own keys): ↑/↓ walk the track-list cursor and ↩ plays it;
        // ←/→ seek ±10s; ⌘↑/↓ volume. The list is the default owner of the bare
        // arrows — no focus mode to enter or a cursor to re-acquire.
        .background {
            if !urlFieldFocused && !searchFieldFocused && !renameFieldFocused {
                Group {
                    Button("") { controller.seekBy(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { controller.seekBy(10) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { controller.adjustVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { controller.adjustVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { moveSelection(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
                    Button("") { playSelectedTrack() }.keyboardShortcut(.return, modifiers: [])
                    Button("") { selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: .command)
                }
                .hidden()
            }
        }
        // Don't let the URL field grab the cursor on launch.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: Fullscreen (the whole player, spread across the big screen)

    /// Fullscreen reuses every normal control — nothing is lost. It just lays the
    /// player out in two columns (now-playing on the left, library/queue on the
    /// right) over a blurred-artwork backdrop, with a larger visualizer.
    private var fullscreenContent: some View {
        GeometryReader { geo in
            // Scale the cover and the list to the actual screen so it truly fills,
            // and center the two columns so there's no top-left void.
            let artSize = min(max(geo.size.height * 0.5, 340), 660)
            let rightWidth = min(max(geo.size.width * 0.30, 420), 780)
            ZStack {
                fullscreenBackdrop
                HStack(alignment: .top, spacing: 60) {
                    VStack(spacing: 16) {
                        heroSlot(width: artSize, height: artSize)
                        infoStrip
                        visualizerStrip
                        positionSlider
                        transportRow
                        utilityRow
                        downloadBar
                    }
                    .frame(width: artSize)
                    // Measure the left column so the library can match its height exactly.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ColumnHeightKey.self, value: proxy.size.height)
                    })

                    fullscreenLibrary(height: fsLeftHeight)
                        .frame(width: rightWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(ColumnHeightKey.self) { fsLeftHeight = max($0, 320) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        // Files & URLs only (not plain text) so an internal reorder drag doesn't
        // trigger the window's drop highlight.
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { handleDrop($0) }
        .overlay(alignment: .bottom) { bottomToasts }
        // Esc: if a field/search is active, just dismiss it — only leave fullscreen
        // when nothing is focused (otherwise pressing Esc to clear a field would
        // unexpectedly collapse the window).
        .onExitCommand {
            if searchActive {
                withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                searchText = ""
                searchFieldFocused = false
            } else if urlFieldFocused || searchFieldFocused {
                dismissFocus()
            } else {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        // ⌘, toggles the inline settings panel here too.
        .onReceive(NotificationCenter.default.publisher(for: .toggleSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
        }
        // ←/→ seek ±10s, ⌘↑/↓ volume, ↑/↓ walk the track-list cursor + ↩ plays it
        // (space is handled by the play button itself).
        .background {
            if !urlFieldFocused && !searchFieldFocused && !renameFieldFocused {
                Group {
                    Button("") { controller.seekBy(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { controller.seekBy(10) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { controller.adjustVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { controller.adjustVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { moveSelection(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
                    Button("") { playSelectedTrack() }.keyboardShortcut(.return, modifiers: [])
                    Button("") { selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: .command)
                }
                .hidden()
            }
        }
    }

    private var fullscreenBackdrop: some View {
        ZStack {
            Color.black
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.28)
                    .scaleEffect(1.2)
            }
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: Backdrop (blurred artwork behind everything)

    /// Solid black — song/video covers are usually on black, so a uniform black
    /// window makes the artwork blend in seamlessly (no "extra" backdrop).
    private var backdrop: some View {
        Color.black
    }

    // MARK: Hero artwork (whole photo, never cropped)

    private var heroArt: some View { heroArtView(width: contentWidth, height: artHeight) }

    /// The breathing cover, at an arbitrary size (fullscreen uses a big square).
    private func heroArtView(width: CGFloat, height: CGFloat) -> some View {
        // The artwork gently "breathes" with the bass while playing (capped at
        // 30fps, and stopped when paused so it doesn't spin the CPU while idle).
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !engine.isPlaying)) { _ in
            // bassLevel eases to 0 when paused, so the scale glides back to 1
            // smoothly instead of snapping.
            let bass = CGFloat(min(max(engine.analyzer.bassLevel, 0), 1))
            artworkContent(width: width, height: height).scaleEffect(1 + bass * 0.035)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Click the cover to dismiss the URL field's cursor.
        .contentShape(Rectangle())
        .onTapGesture { dismissFocus() }
    }

    private func artworkContent(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let image = artworkImage {
                // Photo FILLS the whole box edge-to-edge (no bands); overflow clipped.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: height > 400 ? 130 : 92))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(width: width, height: height)
        .background(Color.black)
    }

    // MARK: Now-playing info

    private var infoStrip: some View {
        let track = controller.currentTrack
        let hasArtist = !(track?.artist.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 3) {
            // Title line: click the title to copy it; a YouTube-sourced track also
            // reveals an "open on YouTube" link on hover, tucked after the title.
            HStack(spacing: 6) {
                MarqueeText(text: nowPlayingTitle, fontSize: 15, bold: true, color: .white)
                    .copyOnClick(nowPlayingTitle, help: "Click to copy title", enabled: track != nil)
                if let youtubeURL = track?.youtubeURL {
                    Button { openInBrowser(youtubeURL) } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .tooltip("Open on YouTube")
                    .opacity(nowPlayingHover ? 1 : 0)
                    .allowsHitTesting(nowPlayingHover)
                }
            }
            HStack(spacing: 8) {
                Text(nowPlayingArtist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                    .copyOnClick(nowPlayingArtist, help: "Click to copy artist", enabled: hasArtist)
                Spacer(minLength: 8)
                SeekTimeLabel(clock: engine.clock, isScrubbing: isScrubbing,
                              scrubTime: scrubTime, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { nowPlayingHover = $0 }
        .animation(.easeOut(duration: 0.15), value: nowPlayingHover)
        // Right-click mirrors the click affordances, so the actions are also
        // discoverable the standard macOS way.
        .contextMenu {
            if let track {
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
            }
        }
    }

    private var visualizerStrip: some View {
        VisualizerView(engine: engine, mode: $visualizerMode, theme: controller.theme,
                       rows: isFullscreen ? 22 : 16, columnScale: isFullscreen ? 2 : 1,
                       transparentBackground: isFullscreen)
            .frame(height: isFullscreen ? 88 : 48)
            .frame(maxWidth: .infinity)
    }

    // MARK: Position slider

    private var positionSlider: some View {
        WaveformSeekBar(clock: engine.clock, waveforms: controller.waveforms,
                        engine: engine, accent: accent,
                        isScrubbing: $isScrubbing, scrubTime: $scrubTime, seekHoverX: $seekHoverX)
    }

    // MARK: Transport

    private var transportRow: some View {
        // Spotify-style: plain icons, one big Play, shuffle/repeat inline, centered.
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            toggleIcon("shuffle", active: controller.shuffle, size: 15, help: "Shuffle") {
                controller.shuffle.toggle()
            }
            iconButton("backward.end", size: 15, help: "Previous  ⌘◀") { controller.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            iconButton("gobackward.10", size: 15, help: "Back 10 seconds  ◀") { controller.seekBy(-10) }
            playButton
            iconButton("goforward.10", size: 15, help: "Forward 10 seconds  ▶") { controller.seekBy(10) }
            iconButton("forward.end", size: 15, help: "Next  ⌘▶") { controller.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            toggleIcon(controller.repeatMode == .one ? "repeat.1" : "repeat",
                       active: controller.repeatMode != .off, size: 15, help: "Repeat") {
                controller.cycleRepeat()
            }
            Spacer(minLength: 0)
        }
    }

    private var playButton: some View {
        Button { controller.togglePlayPause() } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(accent))
                .shadow(color: accent.opacity(0.5), radius: 8)
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.06))
        .tooltip(engine.isPlaying ? "Pause" : "Play")
        .keyboardShortcut(.space, modifiers: [])
    }

    /// Plain transport icon — no background circle (Spotify-style).
    private func iconButton(_ symbol: String, size: CGFloat, weight: Font.Weight = .medium,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(help)
    }

    /// Toggle icon (shuffle/repeat) — green when active, gray when off.
    private func toggleIcon(_ symbol: String, active: Bool, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? accent : .white.opacity(0.55))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip(help)
    }

    // MARK: Utility row (open file + volume — de-emphasized)

    private var utilityRow: some View {
        HStack(spacing: 8) {
            iconButton("folder", size: 13, help: "Open file") { openFile() }
            Spacer()
            // A normal icon button like its neighbours (hover/press feedback), but
            // with an AppKit click-catcher on top. The menu-bar player is a
            // `.nonactivatingPanel`, which never becomes key from a plain button
            // press, so a bare SwiftUI Button only fired after the volume NSSlider
            // (which does take key) had been touched. FirstMouseButton owns the
            // click and works without the panel being key.
            Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(engine.isMuted ? .red.opacity(0.85) : .white.opacity(0.85))
                .brightness(muteHovering ? 0.10 : 0)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                // Grow on hover to match the neighbouring buttons. The catcher on top
                // eats the hover events, so it reports them back to drive the scale.
                .scaleEffect(muteHovering ? 1.10 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: muteHovering)
                .overlay(FirstMouseButton(action: { engine.toggleMute() },
                                          onHover: { muteHovering = $0 }))
                .tooltip(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...1)
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 96)
                .scrollToAdjust { engine.volume = min(max(engine.volume + Float($0) * 0.05, 0), 1) }
        }
    }

    // MARK: Top bar (settings lives here, top-right)

    /// The cover slot: artwork (or the Settings panel), with the settings toggle
    /// and sleep badge floating over its top corners — no separate top bar needed.
    private func heroSlot(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if showSettings {
                SettingsView(controller: controller, width: width, height: height)
                    .transition(.opacity)
            } else if showLyrics {
                LyricsView(controller: controller, clock: engine.clock, width: width, height: height)
                    .transition(.opacity)
            } else {
                heroArtView(width: width, height: height)
            }
            HStack(spacing: 8) {
                // The sleep badge floats over the artwork only — over the Settings
                // panel it would collide with the "Settings" title (and the panel
                // shows its own countdown), and over Lyrics it covers the words.
                if !showSettings && !showLyrics {
                    if let remaining = controller.sleepRemaining {
                        sleepBadge(timeString(remaining))
                    } else if controller.sleepMode == .endOfTrack {
                        sleepBadge("track end")
                    }
                }
                Spacer()
                lyricsToggle
                settingsToggle
            }
            .padding(10)
            .frame(width: width)
        }
        .frame(width: width, height: height)
    }

    private var lyricsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showLyrics.toggle()
                if showLyrics { showSettings = false }
            }
        } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showLyrics ? accent : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip("Lyrics")
    }

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showSettings.toggle()
                if showSettings { showLyrics = false }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showSettings ? accent : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .tooltip("Settings")
    }

    private func sleepBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.35)))
    }

    // MARK: Library section (header with expandable search + track list)

    /// Normal window: fixed-height list.
    private var librarySection: some View { libraryCard(list: trackScroll(fixedHeight: 168)) }

    /// Fullscreen: the card fills an exact height (matched to the left column), the
    /// list stretches to fill it, and it stays transparent so it blends into the
    /// dark backdrop instead of reading as a lighter panel.
    private func fullscreenLibrary(height: CGFloat) -> some View {
        libraryCard(list: trackScroll(fixedHeight: nil), plain: true).frame(height: height)
    }

    private func libraryCard(list: some View, plain: Bool = false) -> some View {
        VStack(spacing: 0) {
            if let playlist = selectedPlaylist { playlistHeader(playlist) } else { libraryHeader }
            // Keep the source switcher present while searching too: toggling it in/out
            // changed the height above the list, which nudged the scroll position on
            // every open/close of search.
            sourceBar
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 6).padding(.top, 6)
            list
        }
        // Floating action bar for the current multi-selection, so bulk Favorite /
        // Playlist / Queue / Delete are one visible tap away — not hidden behind a
        // right-click. Slides up from the bottom of the card when 2+ rows are picked.
        .overlay(alignment: .bottom) { selectionBar }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection.count >= 2)
        // Transparent fill in fullscreen so it blends with the dark backdrop, but
        // always keep a border so the panel still has defined edges. Both live in
        // .background (not .overlay) so the border never paints over content that
        // draws its own overlays on top of itself, e.g. header button tooltips.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(plain ? Color.clear : .white.opacity(0.05))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(plain ? 0.1 : 0.06))
            }
        )
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            if searchActive {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                SteadyTextField(placeholder: "Search…", text: $searchText, focus: $searchFieldFocused)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
                    searchText = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Text("\(controller.library.tracks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                // Contextual "jump to the playing track" — only while it's off-screen.
                if controller.currentTrack != nil, showNowPlayingPill {
                    nowPlayingPill
                        .transition(.opacity)
                }
                Spacer()
                if !controller.library.tracks.isEmpty {
                    viewMenu
                }
                Button { controller.library.revealInFinder() } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .tooltip("Show in Finder")
                if !controller.library.tracks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { searchActive = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFieldFocused = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .tooltip("Search")
                }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.2), value: showNowPlayingPill)
    }

    /// Scroll the track list to the currently-playing track and highlight it. First
    /// clears anything that would hide it — an active search, the favorites filter,
    /// or a selected playlist that doesn't contain it — then triggers the scroll.
    private func goToCurrentTrack() {
        guard let current = controller.currentTrack else { return }
        if searchActive {
            withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
            searchText = ""
            searchFieldFocused = false
        }
        if controller.favorites.filterActive { controller.favorites.setFilter(false) }
        if let playlist = selectedPlaylist, !controller.tracks(in: playlist).contains(current) {
            suppressTopResetOnce = true   // we're about to centre on the track, not reset to top
            selectSource(nil)
        }
        scrollToCurrentNonce += 1
    }

    // MARK: Keyboard navigation

    /// The tracks the list currently shows, in on-screen order — what ↑/↓ walks.
    /// Mirrors the render: a selected playlist, the collapsible artist sections
    /// (skipping collapsed groups), or the flat/filtered library.
    private var navigableTracks: [Track] {
        if selectedPlaylist != nil { return playlistTracks }
        if controller.library.view == .artist && searchText.isEmpty {
            return artistSections.flatMap { collapsedGroups.contains($0.id) ? [] : $0.tracks }
        }
        return filteredTracks
    }

    /// Move the keyboard cursor by `delta`, seeding at the playing row (if shown)
    /// or an end when nothing is selected yet.
    private func moveSelection(by delta: Int) {
        let tracks = navigableTracks
        guard !tracks.isEmpty else { return }
        let index: Int
        if let id = selectedTrackID, let i = tracks.firstIndex(where: { $0.id == id }) {
            index = min(max(i + delta, 0), tracks.count - 1)
        } else if let current = controller.currentTrack?.id,
                  let i = tracks.firstIndex(where: { $0.id == current }) {
            index = i
        } else {
            index = delta > 0 ? 0 : tracks.count - 1
        }
        selectedTrackID = tracks[index].id
        selection = [tracks[index].id]   // arrow keys collapse any multi-selection to the cursor
        selectionIsExplicit = true
        scrollToSelectionNonce += 1   // only keyboard nav scrolls; playback-follow doesn't
    }

    /// Play the row under the cursor, in the scope matching the current source.
    private func playSelectedTrack() {
        guard let id = selectedTrackID,
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
        selectedTrackID = track.id
        selection = [track.id]
        selectionIsExplicit = false   // side effect of playing, not a deliberate pick
        controller.play(track, in: scope)
    }

    /// Route a row click by modifier: ⌘ toggles the row in/out of the selection
    /// (no playback), ⇧ selects the range from the anchor to the clicked row, and
    /// a plain click plays it (collapsing the selection to just that row). Keeps the
    /// Winamp-style click-to-play while layering standard macOS multi-select on top.
    private func handleRowTap(_ track: Track, in scope: [Track]?) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if !selectionIsExplicit {
                // The current `selection` is just the playback-follow highlight, not
                // a deliberate pick. ⌘-clicking the playing track itself should
                // promote it to an explicit selection (rather than toggling it back
                // off) so it outlines. ⌘-clicking any other track starts a fresh
                // explicit selection with just that row — otherwise the playing
                // track would silently tag along and outline as if also picked.
                selection = track.id == controller.currentTrack?.id ? selection.union([track.id]) : [track.id]
                selectionIsExplicit = true
            } else if selection.contains(track.id) {
                selection.remove(track.id)
            } else {
                selection.insert(track.id)
            }
            selectedTrackID = track.id   // anchor follows the last ⌘-click
        } else if mods.contains(.shift), let anchor = selectedTrackID {
            let tracks = navigableTracks
            if let a = tracks.firstIndex(where: { $0.id == anchor }),
               let b = tracks.firstIndex(where: { $0.id == track.id }) {
                let range = a <= b ? a...b : b...a
                selection = Set(tracks[range].map { $0.id })   // anchor stays fixed for further ⇧-clicks
                selectionIsExplicit = true
            }
        } else {
            selectAndPlay(track, in: scope)
        }
    }

    /// The selected tracks in on-screen order (empty when nothing is selected).
    private var selectedTracks: [Track] {
        navigableTracks.filter { selection.contains($0.id) }
    }

    /// Select every track in the current view (⌘A).
    private func selectAll() {
        let tracks = navigableTracks
        guard !tracks.isEmpty else { return }
        selection = Set(tracks.map { $0.id })
        selectionIsExplicit = true
    }

    /// Delete the whole selection through the failure-aware bulk path, then clear.
    private func deleteSelection() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            controller.delete(tracks)
            selection.removeAll()
        }
    }

    /// The bulk context menu for a row, or nil unless the row is part of a
    /// multi-selection (more than one row selected and this row among them).
    /// `playlist` non-nil adds a "Remove from Playlist" bulk action.
    private func bulkRowMenu(for track: Track, inPlaylist playlist: Playlist? = nil) -> BulkRowMenu? {
        guard selection.contains(track.id), selection.count > 1 else { return nil }
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
                    selection.removeAll()
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
    @ViewBuilder private var selectionBar: some View {
        if selection.count >= 2 {
            let tracks = selectedTracks
            let allFavorited = tracks.allSatisfy { controller.favorites.isFavorite($0.url.path) }
            HStack(spacing: 4) {
                Text("\(selection.count)")
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
                            selection.removeAll()
                        }
                    }
                } else {
                    selectionButton("trash", help: "Delete", tint: .red.opacity(0.9)) { deleteSelection() }
                }

                Divider().frame(height: 15).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4)
                selectionButton("xmark", help: "Clear selection", size: 11) {
                    withAnimation(.easeInOut(duration: 0.2)) { selection.removeAll() }
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

    /// Compact "Now playing" pill in the library header, shown only while the current
    /// track is scrolled out of view; tapping it glides the list back to the track.
    /// Kept deliberately quiet — a translucent accent chip rather than a solid fill —
    /// so it reads as an offer, not a demand, in the muted header.
    private var nowPlayingPill: some View {
        Button { goToCurrentTrack() } label: {
            HStack(spacing: 4) {
                Image(systemName: "music.note").font(.system(size: 10, weight: .bold))
                Text("Now playing").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.15)))
            .fixedSize()
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Source switcher (Library + playlists)

    /// Currently viewed playlist, or nil while the whole library is shown. Falls
    /// back to nil if the selected playlist was deleted.
    private var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        return controller.playlists.playlists.first { $0.id == id }
    }

    /// The selected playlist's tracks resolved against the library (order kept,
    /// missing files dropped).
    private var playlistTracks: [Track] {
        guard let playlist = selectedPlaylist else { return [] }
        return controller.tracks(in: playlist)
    }

    /// Pills that switch the track list between the library and each playlist,
    /// plus a "＋" to make a new one.
    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sourcePill(title: "Library", systemImage: "music.note",
                           selected: selectedPlaylistID == nil) { selectSource(nil) }
                ForEach(controller.playlists.playlists) { playlist in
                    sourcePill(title: playlist.name, systemImage: "music.note.list",
                               selected: selectedPlaylistID == playlist.id) { selectSource(playlist.id) }
                        .contextMenu {
                            Button("Play") { controller.playPlaylist(playlist) }
                            Button("Rename") { beginRename(id: playlist.id, current: playlist.name) }
                            Divider()
                            Button("Delete", role: .destructive) { deletePlaylist(playlist.id) }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                Button { createPlaylist() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(hoverScale: 1.08))
                .tooltip("New playlist")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Animate pills sliding in/out as playlists are created or deleted.
            .animation(.easeInOut(duration: 0.22), value: controller.playlists.playlists.count)
        }
        .scrollIndicators(.never)
    }

    private func sourcePill(title: String, systemImage: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? accent.opacity(0.9) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
        // Animate only the highlight color, not a layout morph — keeps switching crisp.
        .animation(.easeInOut(duration: 0.18), value: selected)
    }

    /// Header shown in place of the LIBRARY header while viewing a playlist.
    private func playlistHeader(_ playlist: Playlist) -> some View {
        HStack(spacing: 8) {
            if renamingPlaylist && renameTargetID == playlist.id {
                SteadyTextField(placeholder: "Playlist name", text: $renameText,
                                font: .system(size: 11, weight: .semibold),
                                textColor: .white,
                                onSubmit: { commitRename() },
                                focus: $renameFieldFocused)
                    .frame(maxWidth: 180)
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused { commitRename() }   // commit when clicked away
                    }
            } else {
                Text(playlist.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
                Text("\(playlist.trackPaths.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            // Same "jump to the playing track" offer as the library header — shown
            // only while the current track is scrolled out of this playlist's view.
            if controller.currentTrack != nil, showNowPlayingPill {
                nowPlayingPill
                    .transition(.opacity)
            }
            Spacer()
            if !playlistTracks.isEmpty {
                Button { controller.playPlaylist(playlist) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .tooltip("Play")
            }
            Button { beginRename(id: playlist.id, current: playlist.name) } label: {
                Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Rename")
            Button { deletePlaylist(playlist.id) } label: {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Delete playlist")
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.2), value: showNowPlayingPill)
    }

    // MARK: Source actions

    private func selectSource(_ id: Playlist.ID?) {
        if renamingPlaylist && id != renameTargetID { cancelRename() }
        // Switch instantly: animating a full header swap (LIBRARY ↔ playlist)
        // interpolates two different layouts and stutters. The pill highlight
        // animates on its own; the list content just swaps cleanly.
        // Hide the pill across a real source switch: the old list's "off-screen"
        // must not leak into the new header for the frame before the new layout
        // reports back (the report re-shows it if the row is genuinely out of
        // view). Same-source clicks keep the pill — the preference value won't
        // change, so no report would come to restore it.
        if id != selectedPlaylistID { showNowPlayingPill = false }
        selectedPlaylistID = id
        if id != nil { searchActive = false; searchText = "" }
    }

    /// Create a playlist, optionally seed it with `track`. When `select` is true
    /// (the ＋ button / Save-queue), switch to it and start inline-naming it right
    /// away; when false (library's "New Playlist…"), create it quietly with its
    /// default name and stay put.
    private func createPlaylist(addingTrack track: Track? = nil, select: Bool = true) {
        let playlist = controller.playlists.create()
        if let track { _ = controller.playlists.add(path: track.url.path, to: playlist.id) }
        if select { beginRename(id: playlist.id, current: playlist.name) }
    }

    /// Create a playlist seeded with several tracks (multi-select "New Playlist…").
    private func createPlaylist(addingTracks tracks: [Track], select: Bool = true) {
        let playlist = controller.playlists.create()
        for track in tracks { _ = controller.playlists.add(path: track.url.path, to: playlist.id) }
        if select { beginRename(id: playlist.id, current: playlist.name) }
    }

    /// Switch to a playlist and turn its header name into a focused text field.
    private func beginRename(id: Playlist.ID, current: String) {
        selectSource(id)
        renameTargetID = id
        renameText = current
        renamingPlaylist = true
        // Focus on the next runloop tick — just late enough for the field to be
        // in the hierarchy, without the visible pause a timed delay adds.
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename() {
        guard renamingPlaylist else { return }
        if let id = renameTargetID { controller.playlists.rename(id, to: renameText) }
        cancelRename()
    }

    private func cancelRename() {
        renamingPlaylist = false
        renameTargetID = nil
        renameFieldFocused = false
    }

    private func deletePlaylist(_ id: Playlist.ID) {
        if selectedPlaylistID == id { selectSource(nil) }
        controller.playlists.delete(id)
    }

    /// Add-to-playlist submenu entries for a library row.
    private func playlistMenuItems(for track: Track) -> [PlaylistMenuItem] {
        let path = track.url.path
        return controller.playlists.playlists.map { playlist in
            PlaylistMenuItem(id: playlist.id, name: playlist.name,
                             contains: playlist.trackPaths.contains(path)) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = controller.playlists.add(path: path, to: playlist.id)
                }
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

    private func trackScroll(fixedHeight: CGFloat?) -> some View {
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
                showNowPlayingPill = !report.visible
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
                // list's offset carries into the incoming one. Instead give each source
                // its own memory: stash where we're leaving, restore where we're going
                // (top for a never-visited source).
                //
                // Do it SYNCHRONOUSLY, straight on the clip view's bounds — not a
                // deferred scroll(to:). SwiftUI keeps the clip offset across the content
                // swap (that's the very leak we're fixing), so writing the target here
                // lands in the same commit as the new content: no extra frame, no
                // pixel-nudge jitter, no layout report that would blink the pill.
                // Setting bounds.origin directly (vs scroll(to:), which clamps to the
                // still-present old content) is safe because the remembered offset
                // always belongs to the incoming source's own content.
                guard let sv = autoScroller.scrollView else { return }
                let clip = sv.contentView
                scrollMemory[oldID] = clip.bounds.origin.y
                let target = scrollMemory[newID] ?? 0
                clip.bounds.origin = NSPoint(x: clip.bounds.origin.x, y: target)
                sv.reflectScrolledClipView(clip)
            }
            .onChange(of: scrollToCurrentNonce) { _, _ in
                guard let id = controller.currentTrack?.id else { return }
                // Defer a runloop so anything we just cleared (search / filter) has
                // laid out, then center the current track.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            // Keep the keyboard cursor on screen — minimal scroll (nil anchor)
            // reveals a just-off-edge row without recentring the whole list.
            // Scroll only for keyboard navigation (nonce-driven), never when the
            // cursor merely follows a track change — that would yank the list.
            .onChange(of: scrollToSelectionNonce) { _, _ in
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
                             durationText: timeString(track.duration),
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
            durationText: timeString(track.duration),
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
            durationText: timeString(track.duration),
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

    // MARK: Sort & group

    /// Header menu: pick the library browse order (Recent / A–Z / Artist). The
    /// button shows the active view's icon; each option carries its own icon.
    private var viewMenu: some View {
        Menu {
            // Favorites is a filter, orthogonal to the sort below — you can view
            // favorites only while still sorting them A–Z, by artist, etc.
            Toggle(isOn: favoritesBinding) {
                Label("Favorites", systemImage: "heart")
            }
            Divider()
            Picker("View", selection: viewBinding) {
                ForEach(LibraryView.allCases, id: \.self) { view in
                    Label(view.label, systemImage: view.symbol).tag(view)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: controller.favorites.filterActive ? "heart.fill" : controller.library.view.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(controller.favorites.filterActive ? Theme.favorite : .white.opacity(0.6))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        // Render the menu as a button so it can take PressableButtonStyle and grow
        // on hover like the folder/search icons beside it (.onHover doesn't fire
        // through a borderless menu).
        .menuStyle(.button)
        .buttonStyle(PressableButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .tooltip("View")
    }

    private var viewBinding: Binding<LibraryView> {
        // No withAnimation here: animating a full reorder of the (lazy) list makes
        // SwiftUI compute transitions for every row, which for a large library
        // takes seconds. Snap to the new order instead — it's instant.
        Binding(get: { controller.library.view },
                set: { new in controller.library.setView(new) })
    }

    private var favoritesBinding: Binding<Bool> {
        Binding(get: { controller.favorites.filterActive },
                set: { on in controller.favorites.setFilter(on) })
    }

    // MARK: Artist sections

    /// Artist view sections: every artist with 2+ tracks becomes its own section
    /// (alphabetical, tracks in track-number order), and all single-track artists
    /// are gathered into one "Various" section at the end — so a diverse library
    /// isn't a wall of one-line headers.
    private var artistSections: [LibrarySection] {
        let groups = Dictionary(grouping: filteredTracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
        var sections: [LibrarySection] = []
        var singles: [Track] = []
        for (name, tracks) in groups {
            if tracks.count >= 2 {
                let ordered = tracks.sorted {
                    ($0.trackNumber ?? .max, $0.displayTitle.lowercased())
                        < ($1.trackNumber ?? .max, $1.displayTitle.lowercased())
                }
                sections.append(LibrarySection(id: name, tracks: ordered, isVarious: false))
            } else {
                singles.append(contentsOf: tracks)
            }
        }
        sections.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        if !singles.isEmpty {
            let ordered = singles.sorted {
                let a = $0.artist.lowercased(), b = $1.artist.lowercased()
                if a != b { return a < b }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            sections.append(LibrarySection(id: "Various", tracks: ordered, isVarious: true))
        }
        return sections
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

    // MARK: Drag reorder
    // The machinery (ghost/shift modifier, auto-scroll, event-monitor session,
    // frame preference) lives in ReorderDrag.swift — its file header explains
    // the architecture. Here is only the wiring into this window's lists:
    // live-drag state updates and the one model commit per drop.

    /// Whether the active drag is a queue item (queue rows key on UUID strings,
    /// list rows on file paths).
    private var dragIsQueueItem: Bool {
        draggingID.flatMap { UUID(uuidString: $0) } != nil
    }

    /// Live drag tick, shared by all three lists. No model mutation happens
    /// here — the rows part around the cursor purely visually (see
    /// ReorderDragModifier) and the single model move lands on drop. Reordering
    /// the model live fed the shifting row frames straight back into the
    /// insertion math, which twitched the rows.
    private func handleReorderDrag(id: String, cursorY: CGFloat, onEnd: @escaping () -> Void) {
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
    private func finishLibraryReorder(path: String) {
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
    private func finishPlaylistReorder(path: String, in playlist: Playlist) {
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
    private func finishQueueReorder(id: String) {
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

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14).padding(.horizontal, 4)
    }

    // MARK: Error toast

    @ViewBuilder private var errorToast: some View {
        if let error = controller.downloader.lastError {
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: error) {
                    try? await Task.sleep(for: .seconds(4))
                    controller.downloader.lastError = nil
                }
        }
    }

    /// A neutral, accent-coloured info toast (e.g. "Already in library") — the
    /// non-error sibling of `errorToast`.
    @ViewBuilder private var noticeToast: some View {
        if let notice = controller.downloader.notice {
            Text(notice)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(accent.opacity(0.9)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.5))
                    controller.downloader.notice = nil
                }
        }
    }

    /// Both transient toasts, stacked at the bottom of the window.
    @ViewBuilder private var bottomToasts: some View {
        VStack(spacing: 8) {
            noticeToast
            errorToast
        }
        .animation(.easeInOut(duration: 0.25), value: controller.downloader.notice)
        .animation(.easeInOut(duration: 0.25), value: controller.downloader.lastError)
    }

    // MARK: Download bar (YouTube URL → mp3)

    private var downloadBar: some View {
        let downloading = controller.downloadsLeft > 0
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Spinner while downloading, link icon otherwise.
                Group {
                    if downloading {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14)
                    } else {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 16)

                // The field is always available — you can queue more links even while
                // a download is in flight. While downloading, its placeholder shows
                // the current status instead of the "paste a URL" hint, so nothing
                // shifts and the input never disappears.
                SteadyTextField(placeholder: (downloading || !urlChips.isEmpty)
                                    ? "Add another…"
                                    : "Paste a YouTube URL…",
                                text: $controller.urlInput,
                                onSubmit: { startDownload() },
                                focus: $urlFieldFocused)
                    // A space finalises the URL before it: chip it right away (also
                    // handles pasting several space-separated links at once).
                    .onChange(of: controller.urlInput) { _, _ in chipCompletedURLs() }
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Status (Preparing… / Downloading X% / Converting to mp3…) lives here
                // now, so the field's placeholder can invite adding to the queue.
                if downloading {
                    AnimatedStatusText(status: controller.downloader.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
                // How many are still queued behind the current download.
                if downloading && controller.downloadsLeft > 1 {
                    Text("\(controller.downloadsLeft)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(accent))
                        .help("\(controller.downloadsLeft) downloads left")
                }
                // ＋ stages the current URL as a chip so you can line up several.
                if controller.urlInput.contains("http") {
                    Button { addURLChip() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Add another link")
                }
                // Download / enqueue — appends to the queue even mid-download.
                if !downloading || canDownload {
                    Button { startDownload() } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(canDownload ? accent : .white.opacity(0.3))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canDownload)
                    .help(downloading ? "Add to queue"
                          : (urlChips.isEmpty ? "Download" : "Download \(pendingURLCount)"))
                }
                // Cancel everything while downloading — stays live through the
                // convert/embed phase too: with staging, cancelling then just
                // discards the half-written file instead of leaving a stray mp3.
                if downloading {
                    Button { controller.cancelDownload() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Cancel all")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    // The capsule fills with accent as the download progresses.
                    if downloading {
                        GeometryReader { geo in
                            Capsule()
                                .fill(accent.opacity(0.22))
                                .frame(width: max(0, geo.size.width * controller.downloader.progress))
                                .animation(.easeOut(duration: 0.3), value: controller.downloader.progress)
                        }
                    }
                }
                .clipShape(Capsule())
            )

            // Chips sit in a reserved slot BELOW the field. The slot keeps a
            // fixed height in BOTH states (input and downloading) so nothing —
            // not the field above nor anything below — ever shifts. Queued
            // chips stay put through their own download and disappear only
            // once that item finishes, so the slot is only empty when there's
            // truly nothing staged or in flight.
            chipsStrip
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            if !downloading && !controller.downloader.isAvailable {
                Text("yt-dlp not found — run: brew install yt-dlp")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: downloading)
    }

    private var chipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Queued/downloading first (left): submitted, stays until its own
                // download finishes. The active one can't be removed individually —
                // use the cancel-all button next to the field for that.
                ForEach(controller.downloadQueue) { item in
                    let isActive = item.id == controller.currentDownloadID
                    urlChip(label: shortURL(item.url), active: isActive, shaking: shakingChipURL == item.url) {
                        controller.removeFromQueue(item.id)
                    }
                }
                // Staged (right): typed via ＋, not yet submitted — always removable.
                // Kept AFTER the queue so a staged chip promoting to a queued one
                // appears in place instead of sliding the row leftward (which read
                // as a right-to-left animation).
                ForEach(Array(urlChips.enumerated()), id: \.offset) { index, url in
                    urlChip(label: shortURL(url), active: false, shaking: shakingChipURL == url) {
                        urlChips = urlChips.enumerated().filter { $0.offset != index }.map(\.element)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One chip. `active` chips (currently downloading) show a spinner instead
    /// of the link icon and drop their remove button.
    private func urlChip(label: String, active: Bool, shaking: Bool = false,
                         onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if active {
                ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 8, height: 8)
            } else {
                Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundStyle(accent)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            if !active {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { onRemove() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        // Flash a stronger accent while shaking, so the eye lands on the dupe.
        .background(Capsule().fill(accent.opacity(shaking ? 0.30 : 0.14)))
        .overlay(Capsule().stroke(accent.opacity(shaking ? 0.7 : 0.25)))
        .modifier(Shake(animatableData: shaking ? 1 : 0))
        .animation(.linear(duration: 0.4), value: shaking)
        // Fade in (no centre-anchored scale, which made the capsule pop and the
        // label appear to slide into place); keep the tidy scale-out on removal.
        .transition(.asymmetric(insertion: .opacity,
                                removal: .scale.combined(with: .opacity)))
    }

    private var canDownload: Bool {
        controller.downloader.isAvailable && (!urlChips.isEmpty || controller.urlInput.contains("http"))
    }

    private var pendingURLCount: Int {
        urlChips.count + (controller.urlInput.contains("http") ? 1 : 0)
    }

    /// Called as the field changes: any token the user has "finished" with a
    /// space (typed or pasted) becomes a chip immediately, if it's a valid URL.
    /// Whatever is still being typed after the last space stays in the field.
    private func chipCompletedURLs() {
        guard controller.urlInput.contains(" ") else { return }
        let taken = { Set(self.urlChips).union(self.controller.downloadQueue.map(\.url)) }
        while let space = controller.urlInput.firstIndex(of: " ") {
            let head = String(controller.urlInput[..<space]).trimmingCharacters(in: .whitespaces)
            let tail = String(controller.urlInput[controller.urlInput.index(after: space)...])
            if head.isEmpty { controller.urlInput = tail; continue }  // stray/leading space
            // Stop at the first non-URL token so we never eat plain text.
            guard head.contains("http") else { break }
            if controller.isAlreadyDownloaded(head) {   // instant, no yt-dlp
                controller.downloader.notice = "Already in library"
                controller.urlInput = tail
                continue
            }
            if !taken().contains(head) {
                withAnimation(.easeInOut(duration: 0.2)) { urlChips.append(head) }
            } else {
                flagDuplicate(head)   // already staged/queued — shake it, don't silently drop
            }
            controller.urlInput = tail
        }
    }

    /// Turn the current field into a chip so another link can be added.
    /// Skips URLs already staged or already queued/downloading.
    private func addURLChip() {
        let url = controller.urlInput.trimmingCharacters(in: .whitespaces)
        guard url.contains("http") else { return }
        if controller.isAlreadyDownloaded(url) {         // instant, no yt-dlp
            controller.downloader.notice = "Already in library"
            controller.urlInput = ""
            urlFieldFocused = true
            return
        }
        let taken = Set(urlChips).union(controller.downloadQueue.map(\.url))
        guard !taken.contains(url) else {
            flagDuplicate(url)          // it's already staged/queued — shake that chip
            controller.urlInput = ""
            urlFieldFocused = true
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { urlChips.append(url) }
        controller.urlInput = ""
        urlFieldFocused = true
    }

    /// Shake the existing chip for `url` so re-adding a duplicate reads as a
    /// deliberate "already here" instead of nothing happening. Reset to nil first
    /// so the false→true transition re-fires even on a rapid repeat.
    private func flagDuplicate(_ url: String) {
        shakingChipURL = nil                       // re-arm so a rapid repeat re-fires
        DispatchQueue.main.async {
            shakingChipURL = url                   // the chip animates the shake off this
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                if shakingChipURL == url { shakingChipURL = nil }
            }
        }
    }

    /// Enqueue every staged chip plus the field's URL. A field URL that's already
    /// staged/queued gets the same feedback as ＋ — shake the existing chip instead
    /// of being silently dropped — and one already in the library shows the notice.
    private func startDownload() {
        let field = controller.urlInput.trimmingCharacters(in: .whitespaces)
        if field.contains("http") {
            if controller.isAlreadyDownloaded(field) {
                controller.downloader.notice = "Already in library"
                controller.urlInput = ""
            } else if Set(urlChips).union(controller.downloadQueue.map(\.url)).contains(field) {
                flagDuplicate(field)          // already staged/queued — shake that chip
                controller.urlInput = ""
            }
        }

        let all = (urlChips + [controller.urlInput])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !all.isEmpty else { return }
        controller.download(all.joined(separator: "\n"))   // clears urlInput
        withAnimation(.easeInOut(duration: 0.2)) { urlChips = [] }
        urlFieldFocused = false
    }

    /// A compact label for a chip: the YouTube id if present, else the host.
    private func shortURL(_ url: String) -> String {
        if let match = url.firstMatch(of: /(?:v=|youtu\.be\/|shorts\/)([A-Za-z0-9_-]{11})/) {
            return "▶ \(match.1)"
        }
        return URL(string: url)?.host ?? String(url.prefix(22))
    }

    // MARK: Now-playing text

    private var nowPlayingArtist: String {
        guard let track = controller.currentTrack, !track.artist.isEmpty else { return "SONAR" }
        return track.artist
    }

    private var nowPlayingTitle: String {
        controller.currentTrack?.displayTitle ?? "No track playing"
    }

    /// The list the library section renders. Empty query → the whole library
    /// (cheap, always fresh). Otherwise the precomputed `searchResults`, filled
    /// by the debounced, off-main task — never fuzzy-ranked inside `body`.
    private var filteredTracks: [Track] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? controller.library.tracks
            : searchResults
        guard controller.favorites.filterActive else { return base }
        return base.filter { controller.favorites.isFavorite($0.url.path) }
    }

    /// The scope a library tap plays in. With the favorites filter on, playback
    /// walks the visible favorites (so next/previous stay within them); otherwise
    /// nil lets `play()` default to the whole library.
    private var libraryPlaybackScope: [Track]? {
        controller.favorites.filterActive ? filteredTracks : nil
    }

    /// Fuzzy-rank a (non-empty) query against the library. Static & pure so it can
    /// run on a background task without touching view state. `nonisolated` +
    /// `Sendable` inputs let it hop off the main actor.
    nonisolated static func rank(query: String, tracks: [Track]) -> [Track] {
        tracks
            .compactMap { track -> (track: Track, score: Double)? in
                guard let s = FuzzySearch.score(query, in: [track.displayTitle, track.artist]) else { return nil }
                return (track, s)
            }
            .sorted { $0.score > $1.score }
            .map(\.track)
    }

    // MARK: Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        if !urlProviders.isEmpty {
            Task { @MainActor in
                var files: [URL] = []
                for provider in urlProviders {
                    guard let url = await loadURL(from: provider) else { continue }
                    if url.isFileURL { files.append(url) }
                    else { controller.download(url.absoluteString) }   // a dragged link
                }
                // Import every dropped file at once — added to the library with an
                // "Added" toast, without hijacking playback (same as a download).
                controller.importFiles(files)
            }
            return true
        }

        // Fallback: a dragged plain-text http link (no URL object).
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let text = string as? String, text.contains("http") else { return }
                Task { @MainActor in controller.download(text) }
            }
        }
        return true
    }

    /// Await an `NSItemProvider`'s URL (wraps the callback-based load API).
    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: Helpers

    private func openFile() {
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType(filenameExtension: "flac") {
            contentTypes.append(flac)
        }
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        controller.importFiles(panel.urls)
    }

    /// Drop the cursor from any text field (Esc / click outside).
    private func dismissFocus() {
        urlFieldFocused = false
        searchFieldFocused = false
    }

    private func decodeArtwork(_ track: Track?) {
        artworkImage = track?.artworkData.flatMap { NSImage(data: $0) }
    }

    private func timeString(_ t: TimeInterval) -> String { clockTimeString(t) }
}

private func clockTimeString(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// The "00:34 / 03:12" readout. Observes the clock so only this label — not the
/// whole window — re-renders as the position ticks.
private struct SeekTimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let isScrubbing: Bool
    let scrubTime: TimeInterval
    let accent: Color

    var body: some View {
        Text(clockTimeString(isScrubbing ? scrubTime : clock.currentTime)
             + " / " + clockTimeString(clock.duration))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .fixedSize()
    }
}

/// The position bar, drawn as the track's real waveform. Observes the clock for
/// the live position and the waveform store for the peaks; scrub/hover state is
/// bound back to the parent. Isolated so ticking doesn't re-render the rest of the
/// window. Click/drag anywhere to seek; the played portion is drawn in accent.
private struct WaveformSeekBar: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var waveforms: WaveformStore
    let engine: AudioEngine
    let accent: Color
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    @Binding var seekHoverX: CGFloat?

    /// Column geometry — a thin bar with a hair of gap, SoundCloud-style.
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1
    /// A floor so silent stretches still show a sliver, not a gap.
    private let minBarFraction: CGFloat = 0.08

    /// Prebuilt bar geometry, rebuilt only when the waveform/size changes — never
    /// on a playback tick. See `barsPath`.
    @State private var cache = BarsCache()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = clock.duration
            let position = isScrubbing ? scrubTime : clock.currentTime
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0

            Canvas { context, size in
                // Static bars, built once per (waveform, size). Per tick only the
                // progress clip moves: fill the whole waveform muted, then repaint
                // the played span in accent through a clip rect. Two fills, no
                // per-tick path building — the 10 Hz redraw stays nearly free.
                let bars = barsPath(size: size)
                context.fill(bars, with: .color(.white.opacity(0.22)))
                let playedWidth = CGFloat(progress) * size.width
                if playedWidth > 0 {
                    context.clip(to: Path(CGRect(x: 0, y: 0, width: playedWidth, height: size.height)))
                    context.fill(bars, with: .color(accent))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Hover anywhere to preview the time at that position.
            .overlay {
                if let x = seekHoverX, duration > 0 {
                    let frac = min(max(x / width, 0), 1)
                    TooltipLabel(text: clockTimeString(frac * duration))
                        .position(x: min(max(x, 24), width - 24), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): seekHoverX = point.x
                case .ended: seekHoverX = nil
                }
            }
            // Click or drag anywhere on the waveform to seek. minimumDistance 0 so
            // a plain click (no drag) still lands a seek at that x.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        isScrubbing = true
                        scrubTime = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let target = min(max(value.location.x / width, 0), 1) * duration
                        engine.seek(to: target)
                        isScrubbing = false
                    }
            )
            // Scroll over the bar to seek ±~3s per detent.
            .scrollToAdjust { units in
                guard duration > 0, !isScrubbing else { return }
                engine.seek(to: min(max(clock.currentTime + units * 3, 0), duration))
            }
        }
        .frame(height: 30)
    }

    /// The full mirrored-bar shape (both played and unplayed drawn in one colour by
    /// the caller). Rebuilt only when the waveform version or the canvas size
    /// changes; otherwise the cached `Path` is returned untouched, so a playback
    /// tick draws without allocating or looping. With no waveform yet (still
    /// generating, or unreadable) the bars fall to the `minBarFraction` floor, so
    /// the bar always reads as an intentional flat row rather than emptiness.
    ///
    /// Mutating the `@State` cache here is deliberate memoization: `BarsCache` is a
    /// plain reference type (nothing `@Published`), so updating its fields does not
    /// invalidate the view — it just remembers work across redraws.
    private func barsPath(size: CGSize) -> Path {
        let columns = max(1, Int(size.width / (barWidth + barGap)))
        if cache.matches(version: waveforms.version, columns: columns, height: size.height) {
            return cache.path
        }
        let peaks = resample(waveforms.waveform?.peaks ?? [], to: columns)
        let midY = size.height / 2
        var path = Path()
        for i in 0..<columns {
            let peak = peaks.isEmpty ? 0 : CGFloat(peaks[i])
            let barHeight = max(minBarFraction, peak) * (size.height - 2)
            let x = CGFloat(i) * (barWidth + barGap)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        cache.store(path, version: waveforms.version, columns: columns, height: size.height)
        return path
    }

    /// Reduce `peaks` to exactly `count` columns by taking the max over each
    /// column's source range (so transients survive downsampling). Returns the
    /// input unchanged when it already matches, or empty when there's no data.
    private func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard !peaks.isEmpty, count > 0 else { return [] }
        guard peaks.count != count else { return peaks }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = i * peaks.count / count
            let end = max(start + 1, (i + 1) * peaks.count / count)
            var maxV: Float = 0
            for j in start..<min(end, peaks.count) { maxV = max(maxV, peaks[j]) }
            out[i] = maxV
        }
        return out
    }
}

/// Memoizes the seek bar's prebuilt bar `Path` so it's rebuilt only when the
/// waveform (by version) or the canvas geometry changes — not on every playback
/// tick. A reference type held in `@State` so the value persists across the view's
/// redraws.
private final class BarsCache {
    private(set) var path = Path()
    private var version = -1
    private var columns = -1
    private var height: CGFloat = -1

    func matches(version: Int, columns: Int, height: CGFloat) -> Bool {
        self.version == version && self.columns == columns && self.height == height
    }

    func store(_ path: Path, version: Int, columns: Int, height: CGFloat) {
        self.path = path
        self.version = version
        self.columns = columns
        self.height = height
    }
}
