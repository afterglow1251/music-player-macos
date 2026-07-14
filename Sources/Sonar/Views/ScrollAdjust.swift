import SwiftUI
import AppKit

/// Scroll-wheel / trackpad-scroll to nudge a control's value. SwiftUI has no
/// `onScrollWheel` for arbitrary views, so while the cursor is over the view we
/// install a local scroll-wheel monitor and forward a normalized delta to
/// `onScroll` — one unit ≈ one wheel detent, **positive = physically scrolling up**
/// (add it to increase). Overlaying an NSView instead would swallow the slider's
/// own clicks (scroll delivery uses hit-testing), so hover-gating a monitor keeps
/// the underlying control fully interactive. The monitor consumes the event so a
/// parent ScrollView doesn't also move, and is torn down as soon as the cursor
/// leaves (or the view disappears).
struct ScrollToAdjust: ViewModifier {
    let onScroll: (Double) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside ? install() : remove() }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            var dy = event.scrollingDeltaY
            guard dy != 0 else { return event }
            // `scrollingDeltaY` already has the user's "natural scrolling" setting
            // baked in, so the same physical gesture reports opposite signs on a
            // trackpad (natural) vs a mouse wheel. Undo it via
            // `isDirectionInvertedFromDevice` so a physical upward scroll is always
            // positive — otherwise the control's direction flips per device.
            if event.isDirectionInvertedFromDevice { dy = -dy }
            // Trackpads report many small pixel deltas; a wheel reports a few lines.
            // Normalize both to "detents" so callers can use one step size.
            let units = event.hasPreciseScrollingDeltas ? dy / 8 : dy
            onScroll(Double(units))
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// See `ScrollToAdjust`. `onScroll` gets a normalized delta (≈ detents,
    /// positive = up); multiply by your control's per-detent step.
    func scrollToAdjust(_ onScroll: @escaping (Double) -> Void) -> some View {
        modifier(ScrollToAdjust(onScroll: onScroll))
    }
}

/// Debounced commit for scroll-driven seeking. A fast trackpad flick delivers
/// dozens of scroll events a second, and seeking on each one stops/restarts the
/// player node mid-buffer — every cut is an audible click, in aggregate a
/// crackling squeal. So the seek bars move only the visual scrub position per
/// event and hand the real `engine.seek` to `schedule`, which fires it once the
/// event stream has stayed quiet for `settleDelay`.
@MainActor
final class ScrollSeekDebounce {
    /// How long the scroll must stay quiet before the seek commits: longer than
    /// the gaps between events inside one continuous flick (a few ms apart, up
    /// to tens of ms through the momentum tail), short enough that a single
    /// wheel detent still lands as good as instantly.
    private static let settleDelay: Duration = .milliseconds(180)

    private var pending: Task<Void, Never>?

    /// Replace any pending commit with `commit`, to run after the quiet gap.
    func schedule(_ commit: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// Drop the pending commit (a drag gesture is taking over the scrub).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
