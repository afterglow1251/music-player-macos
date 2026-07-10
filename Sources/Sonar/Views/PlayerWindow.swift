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
    @State private var queueEndTargeted = false
    // Gesture-driven library reorder (no system drag → no lag, no stray files).
    @State private var libFrames: [String: CGRect] = [:]
    @State private var libDragging: String?
    @State private var libDragCursorY: CGFloat = 0
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var searchActive = false
    @State private var isDropTargeted = false
    /// Decoded once per track (not per frame) so the breathing animation doesn't
    /// re-decode the artwork 30×/sec.
    @State private var artworkImage: NSImage?
    @FocusState private var urlFieldFocused: Bool
    @FocusState private var searchFieldFocused: Bool

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
                       rows: isFullscreen ? 22 : 16, columnScale: isFullscreen ? 2 : 1)
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
            libraryHeader
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 6)
            list
        }
        // Transparent fill in fullscreen so it blends with the dark backdrop, but
        // always keep a border so the panel still has defined edges.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(plain ? Color.clear : .white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(plain ? 0.1 : 0.06)))
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

    /// A slim drop area below the last row so a track can be dragged to the very
    /// end; shows the same accent line when a drag hovers it.
    private func endDropZone(targeted: Binding<Bool>, onDrop: @escaping (String) -> Void) -> some View {
        Color.clear
            .frame(height: 16)
            .overlay(alignment: .top) {
                if targeted.wrappedValue {
                    Capsule().fill(accent).frame(height: 2.5).padding(.horizontal, 6)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let source = items.first else { return false }
                onDrop(source)
                return true
            } isTargeted: { targeted.wrappedValue = $0 }
    }

    private func trackScroll(fixedHeight: CGFloat?) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Queue lives at the top of the same list; hidden while searching.
                if !controller.queue.isEmpty && !searchActive {
                    queueHeader
                    ForEach(Array(controller.queue.enumerated()), id: \.element.id) { index, item in
                        QueueRowView(
                            track: item.track,
                            position: index + 1,
                            onRemove: {
                                withAnimation(.easeInOut(duration: 0.2)) { controller.removeFromQueue(item) }
                            },
                            reorderID: item.id.uuidString,
                            onDropReorder: { source in
                                guard let uid = UUID(uuidString: source) else { return }
                                withAnimation(.easeInOut(duration: 0.2)) { controller.moveQueue(id: uid, before: item) }
                            }
                        )
                    }
                    endDropZone(targeted: $queueEndTargeted) { source in
                        guard let uid = UUID(uuidString: source) else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { controller.moveQueueToEnd(id: uid) }
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)
                }

                if controller.library.tracks.isEmpty {
                    emptyMessage("Your library is empty — paste a URL or open a file")
                } else if filteredTracks.isEmpty {
                    emptyMessage("No tracks match “\(searchText)”")
                }
                ForEach(filteredTracks) { track in
                    let path = track.url.path
                    TrackRowView(
                        track: track,
                        isCurrent: controller.currentTrack == track,
                        isPlaying: engine.isPlaying,
                        durationText: timeString(track.duration),
                        onTap: { controller.play(track) },
                        onPlayNext: { withAnimation(.easeInOut(duration: 0.2)) { controller.playNext(track) } },
                        onAddToQueue: { withAnimation(.easeInOut(duration: 0.2)) { controller.addToQueue(track) } },
                        onDelete: { controller.delete(track) },
                        queueHasItems: !controller.queue.isEmpty,
                        // Reorder only when not searching.
                        reorderID: searchText.isEmpty ? path : nil,
                        isDragging: libDragging == path,
                        onReorderChanged: { y in handleLibraryReorder(path: path, cursorY: y) },
                        onReorderEnded: {
                            controller.library.commitOrder()
                            withAnimation(.easeInOut(duration: 0.18)) { libDragging = nil }
                        }
                    )
                    // The dragged row follows the cursor; its slot's midY drives the
                    // offset so it stays glued to the finger as others shift.
                    .offset(y: libDragging == path ? libDragCursorY - (libFrames[path]?.midY ?? libDragCursorY) : 0)
                    .zIndex(libDragging == path ? 1 : 0)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFrameKey.self,
                                               value: [path: proxy.frame(in: .named("reorder"))])
                    })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .coordinateSpace(.named("reorder"))
            .onPreferenceChange(RowFrameKey.self) { libFrames = $0 }
        }
        .frame(height: fixedHeight)
        .frame(maxHeight: fixedHeight == nil ? .infinity : nil)
        .scrollIndicators(.hidden)
    }

    /// Reorder the library live from the cursor's y position — pure math, so the
    /// insertion never lags behind the finger.
    private func handleLibraryReorder(path: String, cursorY: CGFloat) {
        if libDragging != path { libDragging = path }
        libDragCursorY = cursorY
        let others = filteredTracks.filter { $0.url.path != path }
        let target = others.filter { (libFrames[$0.url.path]?.midY ?? .greatestFiniteMagnitude) < cursorY }.count
        if controller.library.tracks.firstIndex(where: { $0.url.path == path }) != target {
            withAnimation(.easeInOut(duration: 0.18)) { controller.library.reorder(path: path, toIndex: target) }
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
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                SteadyTextField(placeholder: "Paste a YouTube URL…",
                                text: $controller.urlInput,
                                onSubmit: {
                                    controller.downloadFromInput()
                                    urlFieldFocused = false
                                },
                                focus: $urlFieldFocused)
                Button {
                    controller.downloadFromInput()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(controller.downloader.isDownloading ? .white.opacity(0.3) : accent)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(controller.downloader.isDownloading || !controller.downloader.isAvailable)
                .help("Download to Music/")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.08)))

            if controller.downloader.isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: controller.downloader.progress).tint(accent)
                    AnimatedStatusText(status: controller.downloader.status)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 118, alignment: .trailing)
                    Button { controller.cancelDownload() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
            } else if !controller.downloader.isAvailable {
                Text("yt-dlp not found — run: brew install yt-dlp")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
