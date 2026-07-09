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
    @FocusState private var urlFieldFocused: Bool

    /// Accent — the signature Winamp green, used sparingly.
    private let accent = Color(red: 0.29, green: 0.87, blue: 0.42)

    private let contentWidth: CGFloat = 460
    private let artHeight: CGFloat = 340

    private var engine: AudioEngine { controller.engine }

    var body: some View {
        VStack(spacing: 14) {
            heroArt
            infoStrip
            visualizerStrip
            positionSlider
            transportRow
            downloadBar
            trackList
        }
        .padding(16)
        .frame(width: contentWidth + 32)
        // Click any empty (black) area to dismiss the URL field's cursor.
        .background(
            backdrop
                .contentShape(Rectangle())
                .onTapGesture { urlFieldFocused = false }
        )
        // Escape removes the cursor from the URL field.
        .onExitCommand { urlFieldFocused = false }
        // Don't let the URL field grab the cursor on launch.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
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
        ZStack {
            if let data = controller.currentTrack?.artworkData, let image = NSImage(data: data) {
                // Fixed box → the window never resizes between tracks. The photo
                // FILLS the whole box edge-to-edge (no bands); overflow is clipped.
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Click the cover to dismiss the URL field's cursor.
        .contentShape(Rectangle())
        .onTapGesture { urlFieldFocused = false }
    }

    // MARK: Now-playing info

    private var infoStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(nowPlayingTitle)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack {
                Text(nowPlayingArtist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                Text(timeString(isScrubbing ? scrubTime : engine.currentTime)
                     + " / " + timeString(engine.duration))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visualizerStrip: some View {
        VisualizerView(engine: engine, mode: $visualizerMode)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08)))
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
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            iconButton("folder", size: 15, help: "Open file") { openFile() }
            iconButton("stop.fill", size: 14, help: "Stop (⌘.)") { engine.stop() }
                .keyboardShortcut(".", modifiers: .command)
            iconButton("backward.fill", size: 16, help: "Previous (⌘←)") { controller.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            playButton
            iconButton("forward.fill", size: 16, help: "Next (⌘→)") { controller.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Button { engine.toggleMute() } label: {
                Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(engine.isMuted ? .red.opacity(0.85) : .white.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PressableButtonStyle())
            .help(engine.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.volume }, set: { engine.volume = $0 }), in: 0...1)
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 56)

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

    private func iconButton(_ symbol: String, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }

    // MARK: Download bar (YouTube URL → mp3)

    private var downloadBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                ZStack(alignment: .leading) {
                    // Custom, static placeholder — the native one shifts ~1px
                    // between edited/empty states, which looked like jitter.
                    if controller.urlInput.isEmpty {
                        Text("Paste a YouTube URL…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $controller.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .focusEffectDisabled()
                        .focused($urlFieldFocused)
                        .onSubmit {
                            controller.downloadFromInput()
                            urlFieldFocused = false
                        }
                }
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
                        .frame(width: 130, alignment: .trailing)
                }
            } else if !controller.downloader.isAvailable {
                Text("yt-dlp not found — run: brew install yt-dlp")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Track list (library / playlist)

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if controller.library.tracks.isEmpty {
                    Text("Your library is empty — paste a URL or open a file")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 4)
                }
                ForEach(controller.library.tracks) { track in
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
            .padding(6)
        }
        .frame(height: 168)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.06)))
    }

    // MARK: Now-playing text

    private var nowPlayingArtist: String {
        guard let track = controller.currentTrack, !track.artist.isEmpty else { return "WINAMP · MAC" }
        return track.artist
    }

    private var nowPlayingTitle: String {
        controller.currentTrack?.displayTitle ?? "No track playing"
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

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
