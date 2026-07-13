import SwiftUI
import AppKit

/// Enables native macOS fullscreen for the window this view lands in, so the
/// standard green title-bar button (and ⌃⌘F) actually work.
struct FullscreenEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { EnablingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class EnablingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}

/// Intercepts the Escape key *before* AppKit's window machinery sees it, so a
/// press can close an open in-app layer (settings, lyrics, search, a multi-
/// selection) without macOS also collapsing native fullscreen. macOS leaves
/// fullscreen on Esc by itself, and `.onExitCommand` can't stop that because it
/// doesn't consume the key. A local `NSEvent` monitor gets first crack at the
/// event, so returning `nil` from it swallows the press outright.
///
/// `onEscape` returns `true` when it handled the press (we then swallow the event);
/// `false` lets Esc through to its normal behaviour (leaving fullscreen).
struct EscapeInterceptor: NSViewRepresentable {
    let onEscape: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }
    // Re-capture the freshest closure each render so it reads current @State.
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = onEscape
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var handler: () -> Bool = { false }
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 53 == Escape. Only swallow it when the handler claims the press;
                // otherwise let it fall through (so Esc still leaves fullscreen).
                guard event.keyCode == 53, self?.handler() == true else { return event }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Reports a view's measured height, so the fullscreen library panel can be made
/// exactly as tall as the now-playing column beside it.
struct ColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
