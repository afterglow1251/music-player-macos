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
    private var cancellable: AnyCancellable?
    private var clickMonitor: Any?
    private var pressMonitor: Any?
    private var isPanelOpen = false

    private lazy var panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 150),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // Without .fullScreenAuxiliary, the panel isn't recognized as belonging
        // to a fullscreen app's Space — it still draws on top (thanks to the
        // popUpMenu level), but outside clicks land in a Space the panel isn't
        // properly attached to, so the click-to-dismiss monitor never tears it
        // down. .stationary keeps it from participating in Exposé/Spaces drag;
        // .ignoresCycle keeps it out of Cmd-` window cycling.
        p.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let hosting = NSHostingController(
            rootView: MiniPlayerView(controller: controller) { Self.showMainWindow() }
        )
        p.contentViewController = hosting
        return p
    }()

    init(controller: PlayerController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.icon
            button.imagePosition = .imageLeading
            button.alignment = .left
        }

        // Toggle on mouse-DOWN via a local monitor that swallows the event,
        // instead of a button action (which AppKit sends on mouse-up). A button
        // action lets NSButtonCell run its press-tracking, and on mouse-up AppKit
        // clears the highlight AFTER our code runs — sometimes a runloop
        // iteration later — so a dark frame gets committed and the button blinks.
        // Swallowing the mouse-down means that tracking never starts, so nothing
        // ever competes with our `isHighlighted` state. Opening on press also
        // matches native menu-bar menus. (Cmd-click passes through so the item
        // can still be drag-reordered in the menu bar.)
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem.button,
                  event.window === button.window,
                  !event.modifierFlags.contains(.command)
            else { return event }
            self.togglePanel(nil)
            return nil
        }

        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
        refreshButton()
    }

    private static let titleWidth: CGFloat = 160

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
        // Redrawing the button (icon/title) can drop the highlight, so re-assert
        // the open-state indication every refresh.
        setOpenIndication(isPanelOpen)
    }

    private static func title(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: " " + text, attributes: [
            .paragraphStyle: paragraph,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sonar")
        image?.isTemplate = true
        return image
    }()

    // MARK: Panel

    private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            isPanelOpen = false
            panel.orderOut(sender)
            setOpenIndication(false)
            removeClickMonitor()
        } else {
            // Size the panel to its SwiftUI content BEFORE positioning. On the
            // first open the content hasn't laid out yet, so the panel still
            // reports its placeholder height — if we position against that, the
            // window then grows upward to fit and its top slides off-screen.
            if let content = panel.contentView {
                content.layoutSubtreeIfNeeded()
                panel.setContentSize(content.fittingSize)
            }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
            panel.setFrameOrigin(NSPoint(
                x: screenRect.midX - panel.frame.width / 2,
                y: screenRect.minY - panel.frame.height - 4
            ))
            panel.orderFrontRegardless()
            // NOTE: deliberately NOT making the panel key. Becoming key triggers a
            // key-window change that redraws the status button mid-click and blinks
            // its highlight OFF for a frame. The seek bar draws its own accent fill
            // (see MiniScrubber), so it doesn't need the window to be key.
            isPanelOpen = true
            setOpenIndication(true)
            installClickMonitor()
        }
    }

    /// Reflect the panel's open state on the status button, the way native
    /// menu-bar menus stay lit while open.
    ///
    /// Uses `state = .on` + the persistent `isHighlighted` property — NOT the
    /// momentary `highlight(_:)` method, which is the press-tracking API. Since
    /// the mouse-down monitor swallows clicks before NSButtonCell can start
    /// tracking, nothing in AppKit ever clears this state behind our back.
    private func setOpenIndication(_ on: Bool) {
        guard let button = statusItem.button else { return }
        button.state = on ? .on : .off
        button.isHighlighted = on
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func dismiss() {
        isPanelOpen = false
        panel.orderOut(nil)
        setOpenIndication(false)
        removeClickMonitor()
    }

    private static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "player" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
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
        .background(VisualEffect(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(controller.currentTrack?.displayTitle ?? "Nothing playing")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    PressButton(action: onShowMain) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .help("Show Sonar")
                }
                if let artist = controller.currentTrack?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // Custom-drawn scrubber rather than a native Slider: the panel is a
            // non-key window, and AppKit draws a native slider's fill in the gray
            // inactive style there. Making the panel key fixes the color but
            // triggers a key-window change that blinks the status button's
            // highlight. Drawing the fill ourselves needs neither.
            MiniScrubber(
                time: isScrubbing ? scrubTime : engine.currentTime,
                duration: engine.duration,
                accent: accent,
                onScrub: { t in
                    isScrubbing = true
                    scrubTime = t
                },
                onCommit: { t in
                    isScrubbing = false
                    engine.seek(to: t)
                }
            )
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

/// A native visual-effect view (`NSVisualEffectView`) bridged for SwiftUI.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A slim seek bar drawn in SwiftUI, styled after the small native slider:
/// capsule track, accent-colored fill, round white knob. Drawn by hand so the
/// fill keeps its accent color inside the non-key panel (a native Slider there
/// renders its fill in the inactive gray).
private struct MiniScrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    let accent: Color
    let onScrub: (TimeInterval) -> Void
    let onCommit: (TimeInterval) -> Void

    private static let knobSize: CGFloat = 11
    private static let trackHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? CGFloat(min(max(time / duration, 0), 1)) : 0
            let knobX = (geo.size.width - Self.knobSize) * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(accent)
                    .frame(width: knobX + Self.knobSize / 2, height: Self.trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: knobX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub(timeAt(value.location.x, width: geo.size.width)) }
                    .onEnded { value in onCommit(timeAt(value.location.x, width: geo.size.width)) }
            )
        }
        .frame(height: 14)
        .opacity(duration > 0 ? 1 : 0.4)
        .allowsHitTesting(duration > 0)
    }

    private func timeAt(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return TimeInterval(min(max(x / width, 0), 1)) * duration
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
