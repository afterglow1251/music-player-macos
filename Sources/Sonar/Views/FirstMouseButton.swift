import SwiftUI
import AppKit

/// A transparent AppKit overlay that owns *all* clicks on a small control and fires
/// `action` — including clicks in a `.nonactivatingPanel` (the menu-bar player),
/// which never becomes key from a plain button press. Used for the Mute button,
/// whose SwiftUI `Button` only fired after the volume `NSSlider` beside it (which
/// does take key) had been touched. Because this view always wins hit-testing, the
/// SwiftUI hover beneath it never fires either — so it reports its own hover state
/// via `onHover`, letting the caller drive the same grow-on-hover feedback the
/// neighbouring buttons get from `PressableButtonStyle`.
struct FirstMouseButton: NSViewRepresentable {
    let action: () -> Void
    var onHover: ((Bool) -> Void)? = nil
    func makeNSView(context: Context) -> NSView { Catcher(action: action, onHover: onHover) }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let catcher = nsView as? Catcher else { return }
        catcher.action = action
        catcher.onHover = onHover
    }

    private final class Catcher: NSView {
        var action: () -> Void
        var onHover: ((Bool) -> Void)?
        init(action: @escaping () -> Void, onHover: ((Bool) -> Void)?) {
            self.action = action; self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
        // Fire even on the click that merely activates the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action() }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
