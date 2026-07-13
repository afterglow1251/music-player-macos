import AppKit

/// Restores a remembered scroll offset across a lazy content swap.
///
/// Writing the offset once at switch time is not enough: the incoming
/// LazyVStack sizes its document view over several layout passes, and each
/// pass can clamp the offset against a document that is still shorter than
/// the remembered position (returning to the tall library from a short
/// playlist always hit this — the offset snapped to the top). One-shot
/// deferred rewrites don't help either: queued main-queue blocks all drain
/// *before* the CoreAnimation commit that does the clamping.
///
/// So instead of guessing frames, this chases the layout itself: apply the
/// target now, then re-apply every time the document view's frame changes,
/// until the offset sticks (the document grew tall enough to hold it) or a
/// short deadline passes — whichever comes first — then let go.
@MainActor
final class ScrollOffsetRestorer {
    private var observer: NSObjectProtocol?
    private var deadline: DispatchWorkItem?

    /// Start (or restart) chasing `target` in `scrollView`.
    func restore(_ target: CGFloat, in scrollView: NSScrollView) {
        cancel()
        apply(target, to: scrollView)
        // Already there (short lists land on the first write) — nothing to chase.
        guard let doc = scrollView.documentView,
              abs(scrollView.contentView.bounds.origin.y - target) > 0.5 else { return }
        doc.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: doc, queue: .main
        ) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView else { return }
                self.apply(target, to: scrollView)
                // Sticking now — the document accommodates the offset; stop chasing
                // so later resizes (window, live-filter) can't yank the list back.
                if abs(scrollView.contentView.bounds.origin.y - target) <= 0.5 { self.cancel() }
            }
        }
        // Safety valve: if the list never grows that tall again (tracks were
        // removed since the offset was remembered), stop chasing once the swap
        // has clearly settled and accept the clamped position.
        let work = DispatchWorkItem { [weak self] in self?.cancel() }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Stop chasing (also called when a jump-to-track supersedes the restore).
    func cancel() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        deadline?.cancel()
        deadline = nil
    }

    private func apply(_ target: CGFloat, to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        guard clip.bounds.origin.y != target else { return }
        clip.bounds.origin = NSPoint(x: clip.bounds.origin.x, y: target)
        scrollView.reflectScrolledClipView(clip)
    }
}
