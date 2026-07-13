import AppKit
import SwiftUI
import Combine

/// Whether the main player window is already the frontmost, focused window —
/// i.e. whether the panel's "show main window" button would have nothing to do.
@MainActor
final class MainWindowVisibility: ObservableObject {
    @Published var isFrontmost = false
}

/// An `NSPanel` that always claims key appearance. The panel is deliberately
/// never made key (see `togglePanel` — becoming key blinks the status-button
/// highlight), but the AppKit-backed `Slider` then draws its fill in the
/// inactive gray regardless of `.tint`. NSCell decides active-vs-inactive
/// drawing by asking the window's key-APPEARANCE accessors — not
/// `isKeyWindow`, which alone has no effect on the slider. Those accessors
/// are private, so they're shadowed via matching `@objc` selectors rather
/// than `override`; all three variants are covered because different NSCell
/// paths consult different ones (the same trio Firefox's cell-drawing window
/// overrides, see MOZCellDrawWindow in nsNativeThemeCocoa.mm).
private final class KeyAppearancePanel: NSPanel {
    override var isKeyWindow: Bool { true }
    @objc(hasKeyAppearance) var hasKeyAppearance: Bool { true }
    @objc(_hasKeyAppearance) var shadowHasKeyAppearance: Bool { true }
    @objc(_hasActiveAppearance) var shadowHasActiveAppearance: Bool { true }
}

/// A menu-bar presence for Sonar: a status-bar button that reflects play state and
/// pops a compact now-playing panel with transport controls — so you can steer
/// playback without leaving whatever app you're in.
@MainActor
final class MenuBarController {
    private let controller: PlayerController
    private let statusItem: NSStatusItem
    private let windowVisibility = MainWindowVisibility()
    private var cancellable: AnyCancellable?
    private var clickMonitor: Any?
    private var pressMonitor: Any?
    private var isPanelOpen = false
    /// Set true the first time the panel's occlusion becomes `.visible` after an
    /// open. The occlusion-driven dismiss only arms once this is true, so the
    /// initial not-visible→visible transition of opening can't dismiss the panel
    /// it's still bringing on screen.
    private var panelDidAppear = false
    /// The app that owned focus when the panel was opened. A non-activating panel
    /// leaves that app frontmost, and opening over another app's fullscreen Space
    /// makes that app re-post `didActivateApplication` — which must NOT close the
    /// panel. Only activation of a *different* app (a real Cmd-Tab away) does.
    private var frontmostAppAtOpen: pid_t?

    private lazy var panel: NSPanel = {
        let p = KeyAppearancePanel(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 150),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // `.transient`, NOT `.stationary` — they're mutually exclusive flavors of
        // the same window-management group. `.stationary` is desktop-widget
        // semantics: the WindowServer pins such windows to the desktop backdrop
        // and refuses to composite them over another app's fullscreen Space, so
        // the panel "opened" where you couldn't see it (occlusion never became
        // .visible). `.transient` is what native popup menus use, and those render
        // over fullscreen apps just fine. `.fullScreenAuxiliary` additionally
        // admits the panel onto the active fullscreen Space.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let hosting = NSHostingController(
            rootView: MiniPlayerView(controller: controller, clock: controller.engine.clock,
                                      windowVisibility: windowVisibility) { [weak self] in
                // Close the panel first — otherwise the main window becoming key
                // flips `windowVisibility.isFrontmost` while the panel is still
                // showing, and the header re-lays-out (button vanishing, artist
                // label shifting) right before your eyes.
                self?.dismiss()
                Self.showMainWindow()
            }
            // The panel is non-activating so it never becomes key, and SwiftUI
            // then renders its controls in the inactive style — the seek Slider's
            // fill goes gray instead of accent green. Forcing the control-active
            // environment makes controls draw as if the window were key. On
            // macOS 14+ the active style is keyed off `appearsActive`;
            // `controlActiveState` is kept for the deprecated readers.
            .environment(\.appearsActive, true)
            .environment(\.controlActiveState, .key)
        )
        p.contentViewController = hosting

        // Dismiss when a Spaces swipe / Mission Control gesture hides the panel.
        // During those transitions the WindowServer takes windows like this
        // panel off screen, which flips its occlusion state to not-visible —
        // the earliest signal we get that a space gesture began. Without this,
        // a half-swipe that snaps back would "restore" a panel the user
        // expected gone (native popovers close for good), and a completed
        // swipe only closed it ~1s later via app-activation.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen else { return }
                let visible = self.panel.occlusionState.contains(.visible)
                if visible {
                    // The panel has actually landed on screen — arm the dismiss.
                    self.panelDidAppear = true
                    return
                }
                // Only a visible→not-visible transition (a real Spaces swipe /
                // Mission Control move that hides the panel) closes it. The
                // not-visible state *before* the panel has ever appeared is just
                // the opening transition and must be ignored.
                guard self.panelDidAppear else { return }
                self.dismiss()
            }
        }
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
        //
        // This same monitor also dismisses the panel on clicks elsewhere in our
        // OWN app's windows (e.g. the main player window, including while it's
        // fullscreen) — the global monitor below only sees clicks in *other*
        // apps, so without this a click on our own window never closed the panel.
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let button = self.statusItem.button, event.type == .leftMouseDown,
               event.window === button.window, !event.modifierFlags.contains(.command) {
                self.togglePanel(nil)
                return nil
            }
            if self.isPanelOpen, event.window !== self.panel {
                self.dismiss()
            }
            return event
        }

        // Also dismiss when the app resigns active (e.g. Cmd-Tab to another app)
        // — a plain click-away monitor never fires for that since no click occurs.
        //
        // `willResignActive`, not `didResignActive`: "did" only fires once macOS
        // has *finished* animating the app switch (~0.3-0.5s later), so the panel
        // sat on screen through the whole transition before closing. "will" fires
        // right as the switch starts, so the panel is gone before the animation
        // even plays.
        //
        // `MainActor.assumeIsolated`, not `Task { @MainActor in ... }`: `queue:
        // .main` already guarantees this closure runs on the main thread, so
        // hopping through a Task would just defer the dismiss to the next runloop
        // turn — long enough for the panel to visibly flash before closing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }

        // `willResignActiveNotification` only fires when SONAR ITSELF was the
        // active app — but the panel is a `.nonactivatingPanel`, so opening it
        // from the menu bar never activates Sonar. The common case is: some
        // other app is active, you open the panel, then switch (Cmd-Tab) to a
        // different app — Sonar's active state never changes, so that
        // notification never fires. Watching the workspace-wide "an app became
        // active" notification catches this regardless of whether Sonar was ever
        // active.
        //
        // But we must ignore the app that was already frontmost when the panel
        // opened. Opening a non-activating panel over another app's fullscreen
        // Space makes THAT app re-post `didActivateApplication`, which would
        // otherwise slam the panel shut the instant it appears. Only a switch to
        // a genuinely *different* app is a real move away that should close it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen,
                      app.processIdentifier != self.frontmostAppAtOpen
                else { return }
                self.dismiss()
            }
        }

        // NOTE: no `activeSpaceDidChangeNotification` observer. It fired on every
        // switch to a fullscreen app (each is its own Space) — including the
        // Space churn caused by the panel's own appearance — and slammed the
        // panel shut. Real Spaces swipes are handled by the occlusion observer:
        // the WindowServer hides the panel mid-swipe, flipping it visible→
        // not-visible, which is what closes it.

        // Keep the panel's "show main window" button hidden whenever it'd have
        // nothing to do — i.e. whenever the main window is already the frontmost,
        // focused window (including fullscreen: a fullscreen window is still key).
        for name: Notification.Name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowVisibility() }
            }
        }
        refreshWindowVisibility()

        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
        refreshButton()
    }

    private func refreshWindowVisibility() {
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "player" })
        windowVisibility.isFrontmost = NSApp.isActive && (window?.isKeyWindow ?? false)
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
            panelDidAppear = false
            frontmostAppAtOpen = nil
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
            // Reset the "has appeared" latch and record who owns focus, BEFORE
            // ordering front — opening can synchronously post the occlusion /
            // activation notifications the dismiss logic reads.
            panelDidAppear = false
            frontmostAppAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
            panel.orderFrontRegardless()
            // NOTE: deliberately NOT making the panel key. Becoming key triggers a
            // key-window change that redraws the status button mid-click and blinks
            // its highlight OFF for a frame. The native seek Slider still draws in
            // its active style because KeyAppearancePanel reports itself as key.
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
        panelDidAppear = false
        frontmostAppAtOpen = nil
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
    /// Observed directly so the progress bar tracks playback — currentTime no
    /// longer flows through `controller`.
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var windowVisibility: MainWindowVisibility
    let onShowMain: () -> Void

    private var engine: AudioEngine { controller.engine }
    private let accent = Theme.accent
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    /// Debounces scroll-driven seeks; see `ScrollSeekDebounce`.
    @State private var scrollSeek = ScrollSeekDebounce()

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
                    // Scrolls when the title overflows, matching the main window's
                    // now-playing title. `.frame(maxWidth: .infinity)` gives the
                    // marquee all the room left after the fixed "show main" button.
                    MarqueeText(text: controller.currentTrack?.displayTitle ?? "Nothing playing",
                                fontSize: 12, weight: .semibold, color: .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Hidden (not just disabled) while the main window is already
                    // frontmost — clicking it then would have nothing to do.
                    if !windowVisibility.isFrontmost {
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
                if let artist = controller.currentTrack?.artist, !artist.isEmpty {
                    MarqueeText(text: artist, fontSize: 11, weight: .regular, color: .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Native slider, matching the main window's seek bar and the EQ/volume
            // sliders. `.tint(accent)` keeps the fill green even though the panel is
            // a non-key window.
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : clock.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(clock.duration, 0.01),
                onEditingChanged: { editing in
                    if editing { scrollSeek.cancel() }   // the drag owns the scrub now
                    isScrubbing = editing
                    if !editing { engine.seek(to: scrubTime) }
                }
            )
            .controlSize(.mini)
            .tint(accent)
            .disabled(clock.duration <= 0)
            HStack {
                Text(Self.time(clock.currentTime)).font(.system(size: 9, design: .monospaced))
                Spacer()
                Text(Self.time(clock.duration)).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
        // Scroll (wheel or trackpad) over the whole seek strip — the mini
        // slider alone is a sliver of a target — to nudge playback ±3s per
        // detent, same as the main window's seek bar. Each event only moves the
        // scrub position; the one real seek commits once the gesture goes quiet
        // — see `ScrollSeekDebounce` for why.
        .contentShape(Rectangle())
        .scrollToAdjust { units in
            guard clock.duration > 0 else { return }
            let base = isScrubbing ? scrubTime : clock.currentTime
            scrubTime = min(max(base + units * 3, 0), clock.duration)
            isScrubbing = true
            scrollSeek.schedule {
                engine.seek(to: scrubTime)
                isScrubbing = false
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            control("backward.end.fill") { controller.previous() }
            control(engine.isPlaying ? "pause.fill" : "play.fill", size: 20) { controller.togglePlayPause() }
            control("forward.end.fill") { controller.next() }
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
