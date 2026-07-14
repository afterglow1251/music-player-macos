import SwiftUI
import AppKit

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
