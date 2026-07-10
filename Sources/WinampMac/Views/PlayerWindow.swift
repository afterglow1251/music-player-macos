import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main player window — a modern take on Winamp: a big uncropped cover,
/// a blurred artwork backdrop, glassy panels, and the classic tile visualizer.
struct PlayerWindow: View {
    @StateObject private var controller = PlayerController()
    @State private var visualizerMode: VisualizerMode = .spectrum
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var searchActive = false
    @State private var isDropTargeted = false
    /// Decoded once per track (not per frame) so the breathing animation doesn't
    /// re-decode the artwork 30×/sec.
    @State private var artworkImage: NSImage?
    @FocusState private var urlFieldFocused: Bool
    @FocusState private var searchFieldFocused: Bool

    /// Accent — the signature Winamp green, used sparingly.
    private let accent = Color(red: 0.29, green: 0.87, blue: 0.42)

    private let contentWidth: CGFloat = 460
    private let artHeight: CGFloat = 340

    private var engine: AudioEngine { controller.engine }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            // Settings takes the artwork's slot so the visualizer below stays
            // visible — theme/EQ changes preview live while the panel is open.
            if showSettings {
                SettingsView(controller: controller, accent: accent,
                             width: contentWidth, height: artHeight)
                    .transition(.opacity)
            } else {
                heroArt
            }
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
        .onDrop(of: [.fileURL, .url, .text], isTargeted: $isDropTargeted) { handleDrop($0) }
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
            decodeArtwork(controller.currentTrack)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: controller.currentTrack) { _, track in
            decodeArtwork(track)
        }
    }

    // MARK: Backdrop (blurred artwork behind everything)

    /// Solid black — song/video covers are usually on black, so a uniform black
    /// window makes the artwork blend in seamlessly (no "extra" backdrop).
    private var backdrop: some View {
        Color.black
    }

    // MARK: Hero artwork (whole photo, never cropped)

    private var heroArt: some View {
        // The artwork gently "breathes" with the bass while playing (capped at
        // 30fps, and stopped when paused so it doesn't spin the CPU while idle).
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !engine.isPlaying)) { _ in
            // bassLevel eases to 0 when paused, so the scale glides back to 1
            // smoothly instead of snapping.
            let bass = CGFloat(min(max(engine.analyzer.bassLevel, 0), 1))
            artworkContent.scaleEffect(1 + bass * 0.035)
        }
        .frame(width: contentWidth, height: artHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Click the cover to dismiss the URL field's cursor.
        .contentShape(Rectangle())
        .onTapGesture { dismissFocus() }
    }

    private var artworkContent: some View {
        ZStack {
            if let image = artworkImage {
                // Photo FILLS the whole box edge-to-edge (no bands); overflow clipped.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: contentWidth, height: artHeight)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: 92))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(width: contentWidth, height: artHeight)
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
        VisualizerView(engine: engine, mode: $visualizerMode, theme: controller.theme)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
    }

    // MARK: Position slider

    private var positionSlider: some View {
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
    }

    // MARK: Transport

    private var transportRow: some View {
        // Spotify-style: plain icons, one big Play, shuffle/repeat inline, centered.
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            toggleIcon("shuffle", active: controller.shuffle, size: 13, help: "Shuffle") {
                controller.shuffle.toggle()
            }
            iconButton("backward.fill", size: 17, help: "Previous (⌘←)") { controller.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            iconButton("gobackward.10", size: 15, help: "Back 10s (⌥←)") { controller.seekBy(-10) }
            playButton
            iconButton("goforward.10", size: 15, help: "Forward 10s (⌥→)") { controller.seekBy(10) }
            iconButton("forward.fill", size: 17, help: "Next (⌘→)") { controller.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            toggleIcon(controller.repeatMode == .one ? "repeat.1" : "repeat",
                       active: controller.repeatMode != .off, size: 13, help: "Repeat") {
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
        .help(engine.isPlaying ? "Pause (Space)" : "Play (Space)")
        .keyboardShortcut(.space, modifiers: [])
    }

    /// Plain transport icon — no background circle (Spotify-style).
    private func iconButton(_ symbol: String, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }

    /// Toggle icon (shuffle/repeat) — green when active, gray when off.
    private func toggleIcon(_ symbol: String, active: Bool, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? accent : .white.opacity(0.55))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
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
            .help(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...1)
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 96)
        }
    }

    // MARK: Top bar (settings lives here, top-right)

    private var topBar: some View {
        HStack(spacing: 8) {
            if let remaining = controller.sleepRemaining {
                sleepBadge(timeString(remaining))
            } else if controller.sleepMode == .endOfTrack {
                sleepBadge("track end")
            }
            Spacer()
            toggleIcon("slider.horizontal.3", active: showSettings, size: 15,
                       help: "Settings — theme & equalizer (⌘,)") {
                withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
            }
        }
        .frame(height: 24)
    }

    private func sleepBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(accent)
    }

    // MARK: Library section (header with expandable search + track list)

    private var librarySection: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 6)
            trackScroll
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06)))
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { searchActive = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFieldFocused = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Search")
                }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 10)
        .padding(.top, 8).padding(.bottom, 4)
    }

    private var trackScroll: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if controller.library.tracks.isEmpty {
                    emptyMessage("Your library is empty — paste a URL or open a file")
                } else if filteredTracks.isEmpty {
                    emptyMessage("No tracks match “\(searchText)”")
                }
                ForEach(filteredTracks) { track in
                    TrackRowView(
                        track: track,
                        isCurrent: controller.currentTrack == track,
                        isPlaying: engine.isPlaying,
                        accent: accent,
                        durationText: timeString(track.duration),
                        onTap: { controller.play(track) },
                        onDelete: { controller.delete(track) }
                    )
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(height: 168)
        .scrollIndicators(.hidden)
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
                    Text(controller.downloader.status)
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
        guard let track = controller.currentTrack, !track.artist.isEmpty else { return "WINAMP · MAC" }
        return track.artist
    }

    private var nowPlayingTitle: String {
        controller.currentTrack?.displayTitle ?? "No track playing"
    }

    private var filteredTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return controller.library.tracks }
        return controller.library.tracks.filter {
            $0.displayTitle.lowercased().contains(query) || $0.artist.lowercased().contains(query)
        }
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
