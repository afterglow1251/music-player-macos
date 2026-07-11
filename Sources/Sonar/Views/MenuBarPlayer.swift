import AppKit
import SwiftUI
import Combine

/// A menu-bar presence for Sonar: a status-bar button that reflects play state and
/// pops a compact now-playing panel with transport controls — so you can steer
/// playback without leaving whatever app you're in.
@MainActor
final class MenuBarController {
    private let controller: PlayerController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    init(controller: PlayerController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.icon
            button.imagePosition = .imageLeading
            // Anchor the icon to the left edge so it never drifts when the title
            // truncates within the fixed-width slot.
            button.alignment = .left
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 268, height: 150)
        popover.contentViewController = NSHostingController(
            rootView: MiniPlayerView(controller: controller, onShowMain: Self.showMainWindow)
        )

        // Keep the menu-bar button in step with playback (icon + current title).
        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
        refreshButton()
    }

    // MARK: Button

    /// Fixed slot width when a title is shown, so the item (and the popover
    /// anchored to it) never shifts.
    private static let titleWidth: CGFloat = 160

    /// The menu-bar item depends ONLY on which track is loaded — never on play
    /// state — so toggling play/pause leaves it perfectly still (no icon swap, no
    /// resize). Same icon always; the title shows whenever a track is loaded
    /// (playing or paused), truncated within a fixed slot.
    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon
        if let track = controller.currentTrack {
            statusItem.length = Self.titleWidth
            button.attributedTitle = Self.title(track.displayTitle)
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.title = ""
        }
    }

    private static func title(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: " " + text, attributes: [
            .paragraphStyle: paragraph,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }

    /// One stable icon, regardless of play state.
    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sonar")
        image?.isTemplate = true
        return image
    }()

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Bring the main player window back to the front (it may be closed/minimized).
    private static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// The compact now-playing panel shown from the menu-bar button.
private struct MiniPlayerView: View {
    @ObservedObject var controller: PlayerController
    let onShowMain: () -> Void

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 10) {
            header
            progress
            transport
        }
        .padding(12)
        .frame(width: 268)
    }

    private var header: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.currentTrack?.displayTitle ?? "Nothing playing")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let artist = controller.currentTrack?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PressButton(action: onShowMain) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .help("Show Sonar")
        }
    }

    private var artwork: some View {
        Group {
            if let data = controller.currentTrack?.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.black.opacity(0.25)
                    Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var progress: some View {
        VStack(spacing: 3) {
            // The same native slider the main window uses, so the two bars match
            // and pick up the system look (including vibrancy inside the popover).
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
            HStack {
                Text(Self.time(engine.currentTime)).font(.system(size: 9, design: .monospaced))
                Spacer()
                Text(Self.time(engine.duration)).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            control("backward.fill") { controller.previous() }
            control(engine.isPlaying ? "pause.fill" : "play.fill", size: 20) { controller.togglePlayPause() }
            control("forward.fill") { controller.next() }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        PressButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A button that dims (and dips) while held — the way native controls respond.
///
/// Press state is driven by a `DragGesture`, not `ButtonStyle.isPressed`, because
/// inside an `NSPopover` the button-style press state doesn't update reliably,
/// whereas a drag gesture does (the seek bar uses one and works). The `Button`
/// still owns the action so it only fires on a real click released inside.
private struct PressButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            label
                .opacity(pressed ? 0.4 : 1)
                .scaleEffect(pressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
