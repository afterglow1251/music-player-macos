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

/// Reports a view's measured height, so the fullscreen library panel can be made
/// exactly as tall as the now-playing column beside it.
struct ColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
