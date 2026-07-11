import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main player window — a modern retro-skinned player: a big uncropped cover,
/// a blurred artwork backdrop, glassy panels, and the classic tile visualizer.
struct PlayerWindow: View {
    @StateObject private var controller = PlayerController()
    @State private var isFullscreen = false
    @State private var fsLeftHeight: CGFloat = 400   // measured left-column height (fullscreen)
    @State private var visualizerMode: VisualizerMode = .spectrum
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var seekHoverX: CGFloat?   // cursor x over the position slider
    // Gesture-driven reorder, shared by library & queue (ids never collide:
    // library rows key on file path, queue rows on a UUID string).
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingID: String?
    @State private var dragCursorY: CGFloat = 0
    // Grouping (auto by artist for now).
    @State private var groupByArtist = false
    @State private var collapsedGroups: Set<String> = []
    // Source switcher: nil = the whole library, otherwise the viewed playlist.
    @State private var selectedPlaylistID: Playlist.ID?
    @State private var renamingPlaylist = false
    @State private var renameText = ""
    @State private var renameTargetID: Playlist.ID?
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var searchActive = false
    @State private var urlChips: [String] = []   // links queued via the ＋ button
    @State private var isDropTargeted = false
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
        // Also re-decode when only the artwork changes (same track, metadata just
        // finished loading after a download) — same-url tracks compare equal, so
        // the change above wouldn't fire.
        .onChange(of: controller.currentTrack?.artworkData) { _, _ in
            decodeArtwork(controller.currentTrack)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            isFullscreen = false
            // Leaving fullscreen, the resizable window keeps its huge frame — snap
            // it back to the content's natural size so there are no black margins.
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
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
                .onTapGesture { dismissFocus() }
        )
        .overlay(alignment: .bottom) { errorToast }
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
        // Arrow keys: ← → seek ±10s, ↑ ↓ volume. Only active when no text field
        // is focused, so arrows still edit text in the URL/search fields.
        .background {
            if !urlFieldFocused && !searchFieldFocused {
                Group {
                    Button("") { controller.seekBy(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { controller.seekBy(10) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { controller.adjustVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { controller.adjustVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: [])
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
        .overlay(alignment: .bottom) { errorToast }
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
        // ← → seek ±10s, ↑ ↓ volume (space is handled by the play button itself).
        .background {
            if !urlFieldFocused && !searchFieldFocused {
                Group {
                    Button("") { controller.seekBy(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { controller.seekBy(10) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { controller.adjustVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { controller.adjustVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: [])
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
        VStack(alignment: .leading, spacing: 3) {
            MarqueeText(text: nowPlayingTitle, fontSize: 15, bold: true, color: .white)
            HStack(spacing: 8) {
                Text(nowPlayingArtist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(timeString(isScrubbing ? scrubTime : engine.currentTime)
                     + " / " + timeString(engine.duration))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        GeometryReader { geo in
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : engine.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(engine.duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { engine.seek(to: scrubTime) }
                }
            )
            .controlSize(.small)
            .tint(accent)
            .disabled(engine.duration <= 0)
            // Hover anywhere on the bar to preview the time at that position.
            .overlay {
                if let x = seekHoverX, engine.duration > 0 {
                    let frac = min(max(x / geo.size.width, 0), 1)
                    TooltipLabel(text: timeString(frac * engine.duration))
                        .position(x: min(max(x, 24), geo.size.width - 24), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): seekHoverX = point.x
                case .ended: seekHoverX = nil
                }
            }
        }
        .frame(height: 22)
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
            Button { engine.toggleMute() } label: {
                Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(engine.isMuted ? .red.opacity(0.8) : .white.opacity(0.45))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...1)
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 96)
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
            } else {
                heroArtView(width: width, height: height)
            }
            HStack(spacing: 8) {
                if let remaining = controller.sleepRemaining {
                    sleepBadge(timeString(remaining))
                } else if controller.sleepMode == .endOfTrack {
                    sleepBadge("track end")
                }
                Spacer()
                settingsToggle
            }
            .padding(10)
            .frame(width: width)
        }
        .frame(width: width, height: height)
    }

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
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
            if !searchActive { sourceBar }
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 6)
            list
        }
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
                Spacer()
                if !controller.library.tracks.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { groupByArtist.toggle() } } label: {
                        Image(systemName: "person.2")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(groupByArtist ? accent : .white.opacity(0.55))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .tooltip(groupByArtist ? "Ungroup" : "Group by artist")
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
    }

    // MARK: Source actions

    private func selectSource(_ id: Playlist.ID?) {
        if renamingPlaylist && id != renameTargetID { cancelRename() }
        // Switch instantly: animating a full header swap (LIBRARY ↔ playlist)
        // interpolates two different layouts and stutters. The pill highlight
        // animates on its own; the list content just swaps cleanly.
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
                            onReorderChanged: { y in handleQueueReorder(id: qid, cursorY: y) },
                            onReorderEnded: { withAnimation(.easeInOut(duration: 0.18)) { draggingID = nil } }
                        )
                        .modifier(ReorderDragModifier(id: qid, draggingID: draggingID,
                                                      cursorY: dragCursorY, frames: rowFrames))
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)
                }

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
                        emptyMessage("No tracks match “\(searchText)”")
                    }
                    if groupByArtist && searchText.isEmpty {
                        // Collapsible auto-group sections, each playable as its own scope.
                        ForEach(artistSections) { section in
                            groupHeader(section)
                            if !collapsedGroups.contains(section.id) {
                                ForEach(section.tracks) { track in
                                    libraryRow(track, reorderID: nil, scope: section.tracks)
                                }
                            }
                        }
                    } else {
                        ForEach(filteredTracks) { track in
                            libraryRow(track, reorderID: searchText.isEmpty ? track.url.path : nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .coordinateSpace(.named("reorder"))
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
        }
        .frame(height: fixedHeight)
        .frame(maxHeight: fixedHeight == nil ? .infinity : nil)
        .scrollIndicators(.hidden)
    }

    /// One library row. `reorderID` non-nil enables drag; `scope` is the list that
    /// playing this row plays through (a section's tracks, or the whole library).
    private func libraryRow(_ track: Track, reorderID: String?, scope: [Track]? = nil) -> some View {
        let path = track.url.path
        return TrackRowView(
            track: track,
            isCurrent: controller.currentTrack == track,
            isPlaying: engine.isPlaying,
            durationText: timeString(track.duration),
            onTap: { controller.play(track, in: scope) },
            onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(track) } },
            onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(track) } },
            onDelete: { controller.delete(track) },
            queueHasItems: !controller.queue.isEmpty,
            reorderID: reorderID,
            isDragging: draggingID == path,
            onReorderChanged: { y in handleLibraryReorder(path: path, cursorY: y) },
            onReorderEnded: {
                controller.library.commitOrder()
                withAnimation(.easeInOut(duration: 0.18)) { draggingID = nil }
            },
            addToPlaylists: playlistMenuItems(for: track),
            onNewPlaylistWithTrack: { createPlaylist(addingTrack: track, select: false) }
        )
        .modifier(ReorderDragModifier(id: path, draggingID: draggingID,
                                      cursorY: dragCursorY, frames: rowFrames,
                                      enabled: reorderID != nil))
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
            durationText: timeString(track.duration),
            onTap: { controller.play(track, in: scope) },
            onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(track) } },
            onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(track) } },
            onDelete: { controller.delete(track) },
            queueHasItems: !controller.queue.isEmpty,
            reorderID: path,
            isDragging: draggingID == path,
            onReorderChanged: { y in handlePlaylistReorder(path: path, in: playlist, cursorY: y) },
            onReorderEnded: {
                controller.playlists.commit(playlist.id)
                withAnimation(.easeInOut(duration: 0.18)) { draggingID = nil }
            },
            onRemoveFromPlaylist: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controller.playlists.remove(path: path, from: playlist.id)
                }
            }
        )
        .modifier(ReorderDragModifier(id: path, draggingID: draggingID,
                                      cursorY: dragCursorY, frames: rowFrames))
    }

    // MARK: Auto-groups (by artist)

    private var artistSections: [LibrarySection] {
        Dictionary(grouping: filteredTracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
            .map { LibrarySection(id: $0.key, tracks: $0.value) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private func groupHeader(_ section: LibrarySection) -> some View {
        let collapsed = collapsedGroups.contains(section.id)
        return HStack(spacing: 8) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 14)
            Text(section.id)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Text("\(section.tracks.count)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Button { controller.playGroup(section.tracks) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .tooltip("Play")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed { collapsedGroups.remove(section.id) } else { collapsedGroups.insert(section.id) }
            }
        }
    }

    /// Reorder the library live from the cursor's y position — pure math, so the
    /// insertion never lags behind the finger.
    private func handleLibraryReorder(path: String, cursorY: CGFloat) {
        if draggingID != path { draggingID = path }
        dragCursorY = cursorY
        let others = filteredTracks.filter { $0.url.path != path }
        let target = others.filter { (rowFrames[$0.url.path]?.midY ?? .greatestFiniteMagnitude) < cursorY }.count
        if controller.library.tracks.firstIndex(where: { $0.url.path == path }) != target {
            withAnimation(.easeInOut(duration: 0.18)) { controller.library.reorder(path: path, toIndex: target) }
        }
    }

    /// Reorder within a playlist live from the cursor's y position.
    private func handlePlaylistReorder(path: String, in playlist: Playlist, cursorY: CGFloat) {
        if draggingID != path { draggingID = path }
        dragCursorY = cursorY
        let others = playlistTracks.filter { $0.url.path != path }
        let target = others.filter { (rowFrames[$0.url.path]?.midY ?? .greatestFiniteMagnitude) < cursorY }.count
        if selectedPlaylist?.trackPaths.firstIndex(of: path) != target {
            withAnimation(.easeInOut(duration: 0.18)) {
                controller.playlists.reorder(path: path, toIndex: target, in: playlist.id)
            }
        }
    }

    /// Reorder the queue live from the cursor's y position.
    private func handleQueueReorder(id: String, cursorY: CGFloat) {
        if draggingID != id { draggingID = id }
        dragCursorY = cursorY
        guard let uid = UUID(uuidString: id) else { return }
        let others = controller.queue.filter { $0.id.uuidString != id }
        let target = others.filter { (rowFrames[$0.id.uuidString]?.midY ?? .greatestFiniteMagnitude) < cursorY }.count
        if controller.queue.firstIndex(where: { $0.id == uid }) != target {
            withAnimation(.easeInOut(duration: 0.18)) { controller.reorderQueue(id: uid, toIndex: target) }
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

                // The field morphs into the status text in place — same height,
                // so nothing below ever shifts.
                ZStack(alignment: .leading) {
                    if downloading {
                        AnimatedStatusText(status: controller.downloader.status)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        SteadyTextField(placeholder: urlChips.isEmpty ? "Paste a YouTube URL…" : "Add another…",
                                        text: $controller.urlInput,
                                        onSubmit: { startDownload() },
                                        focus: $urlFieldFocused)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if downloading {
                    // How many are still queued behind the current one.
                    if controller.downloadsLeft > 1 {
                        Text("\(controller.downloadsLeft)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(accent))
                            .help("\(controller.downloadsLeft) downloads left")
                    }
                    Button { controller.cancelDownload() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Cancel all")
                } else {
                    // ＋ turns the current URL into a chip so you can add another.
                    if controller.urlInput.contains("http") {
                        Button { addURLChip() } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Add another link")
                    }
                    Button { startDownload() } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(canDownload ? accent : .white.opacity(0.3))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canDownload)
                    .help(urlChips.isEmpty ? "Download" : "Download \(pendingURLCount)")
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
                // Staged: typed via ＋, not yet submitted — always removable.
                ForEach(Array(urlChips.enumerated()), id: \.offset) { index, url in
                    urlChip(label: shortURL(url), active: false) {
                        urlChips = urlChips.enumerated().filter { $0.offset != index }.map(\.element)
                    }
                }
                // Queued/downloading: submitted, stays until its own download
                // finishes. The active one can't be removed individually —
                // use the cancel-all button next to the field for that.
                ForEach(controller.downloadQueue) { item in
                    let isActive = item.id == controller.currentDownloadID
                    urlChip(label: shortURL(item.url), active: isActive) {
                        controller.removeFromQueue(item.id)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One chip. `active` chips (currently downloading) show a spinner instead
    /// of the link icon and drop their remove button.
    private func urlChip(label: String, active: Bool, onRemove: @escaping () -> Void) -> some View {
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
        .background(Capsule().fill(accent.opacity(0.14) as Color))
        .overlay(Capsule().stroke(accent.opacity(0.25) as Color))
        .transition(.scale.combined(with: .opacity))
    }

    private var canDownload: Bool {
        controller.downloader.isAvailable && (!urlChips.isEmpty || controller.urlInput.contains("http"))
    }

    private var pendingURLCount: Int {
        urlChips.count + (controller.urlInput.contains("http") ? 1 : 0)
    }

    /// Turn the current field into a chip so another link can be added.
    /// Skips URLs already staged or already queued/downloading.
    private func addURLChip() {
        let url = controller.urlInput.trimmingCharacters(in: .whitespaces)
        guard url.contains("http") else { return }
        let taken = Set(urlChips).union(controller.downloadQueue.map(\.url))
        guard !taken.contains(url) else {
            controller.urlInput = ""
            urlFieldFocused = true
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { urlChips.append(url) }
        controller.urlInput = ""
        urlFieldFocused = true
    }

    /// Enqueue every chip plus whatever is in the field.
    private func startDownload() {
        let all = (urlChips + [controller.urlInput])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !all.isEmpty else { return }
        controller.download(all.joined(separator: "\n"))
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

    private var filteredTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.library.tracks }
        // Fuzzy: typo-tolerant, ranked best-match first.
        return controller.library.tracks
            .compactMap { track -> (track: Track, score: Double)? in
                guard let s = FuzzySearch.score(query, in: [track.displayTitle, track.artist]) else { return nil }
                return (track, s)
            }
            .sorted { $0.score > $1.score }
            .map(\.track)
    }

    // MARK: Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if url.isFileURL {
                        let track = await controller.library.add(url)
                        controller.play(track)
                    } else {
                        controller.download(url.absoluteString)
                    }
                }
            }
            return true
        }

        _ = provider.loadObject(ofClass: NSString.self) { string, _ in
            guard let text = string as? String, text.contains("http") else { return }
            Task { @MainActor in controller.download(text) }
        }
        return true
    }

    // MARK: Helpers

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let track = await controller.library.add(url)
                controller.play(track)
            }
        }
    }

    /// Drop the cursor from any text field (Esc / click outside).
    private func dismissFocus() {
        urlFieldFocused = false
        searchFieldFocused = false
    }

    private func decodeArtwork(_ track: Track?) {
        artworkImage = track?.artworkData.flatMap { NSImage(data: $0) }
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
