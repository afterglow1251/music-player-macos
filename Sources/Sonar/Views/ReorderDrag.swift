import SwiftUI
import AppKit

// MARK: - Drag-to-reorder machinery
//
// Everything that makes rows draggable lives here; the wiring into the actual
// lists (state, drop commits, the ghost's row content) is in PlayerWindow
// under "MARK: Drag reorder". The design fell out of a series of hard-won
// lessons — change any one piece and check the others still hold:
//
//  1. THE MODEL ORDER IS FROZEN WHILE A DRAG IS LIVE. Early versions reordered
//     the model on every cursor move; the rows' resulting (animated or
//     snapping) frames fed straight back into the insertion math — a feedback
//     loop that oscillated and twitched rows. Instead, rows part around the
//     cursor purely visually (`ReorderDragModifier.shift`), and PlayerWindow
//     commits ONE model move on drop.
//
//  2. THE DRAGGED ROW IS HIDDEN AND A FLOATING GHOST FOLLOWS THE CURSOR.
//     Rows are lazy-stack items: once a row's slot scrolls off-screen the
//     stack removes it from the hierarchy no matter how far it's offset, so
//     "offset the row to the cursor" made the dragged track vanish on long
//     auto-scrolls. The ghost (`PlayerWindow.dragGhost`) is an overlay of the
//     scroll *content* — outside the lazy stack, it can't be culled — and its
//     slot frame is snapshotted at drag start (`draggedFrame`) because the
//     row's live frame dies with the row.
//
//  3. A WINDOW EVENT MONITOR OWNS THE DRAG, NOT THE ROW'S GESTURE. The
//     DragGesture also dies when its row is culled — silently: no updates, no
//     onEnded, a stranded ghost and no drop. The gesture only *starts* the
//     drag; from the first tick `ReorderAutoScroller.beginSession` tracks
//     `leftMouseDragged`/`leftMouseUp` at the window level, which survives the
//     row's death and always delivers the drop.
//
//  4. AUTO-SCROLL IS DISPLAY-LINK DRIVEN AND RE-FIRES THE HANDLER. The
//     gesture/monitor alone never scrolls, so long lists were unreachable.
//     Near the viewport's edge a CADisplayLink scrolls the NSScrollView
//     directly (a free-running Timer judders against the refresh rate), and
//     each tick shifts the cursor's content-space y by the scrolled delta —
//     the insertion point keeps moving while the mouse sits still.
//
//  5. THE DROP INDEX ANCHORS ON THE NEAREST VISIBLE ROW. "Count every row
//     above the cursor" undercounted on long drags: culled rows stop
//     reporting frames. The nearest row with a known frame is on-screen by
//     definition (`PlayerWindow.dropIndex`), and the index follows from the
//     data order. Frames are only reported while a drag is active — reporting
//     on every scroll frame churned the preference into visible jank.
//
// Debug logging for all of this: `PlayerWindow.dragLog` — enable with
// `defaults write com.sonar.player SonarDragDebug -bool YES` (Debug builds).

/// A 6-dot drag handle (2 columns × 3 rows), the affordance for reordering.
struct DragDots: View {
    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow { dot; dot }
            }
        }
    }
    private var dot: some View { Circle().frame(width: 2.5, height: 2.5) }
}

/// Collects each reorderable row's frame (keyed by id) in the list's "reorder"
/// coordinate space, so a drag can compute the target index from cursor
/// position — no hit-testing, no lag.
struct RowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Applied to a reorderable row: reports its settled frame and parts the rows
/// around the cursor while one of them is dragged (see the file header, №1–2).
struct ReorderDragModifier: ViewModifier {
    let id: String
    let draggingID: String?
    let cursorY: CGFloat
    /// The dragged row's slot frame, snapshotted at drag start. Its live frame
    /// can't be trusted mid-drag — the lazy stack culls the row off-screen.
    let draggedFrame: CGRect?
    let frames: [String: CGRect]
    /// When false (e.g. grouped view), do nothing — no frame reporting, so
    /// expanding a section doesn't churn preferences and flicker.
    var enabled: Bool = true
    /// Whether the active drag belongs to this row's section (queue vs list).
    /// Rows never part for a drag from the other section — the dragged item
    /// can't be dropped among them.
    var sectionActive: Bool = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(y: shift)
                // Same curve/duration as the drop's withAnimation, so a shifted
                // row's offset unwinding cancels its slot change exactly and it
                // doesn't move on drop.
                .animation(.easeInOut(duration: 0.18), value: shift)
                // Hide only once the ghost can take over (frame snapshotted).
                // Not animated: the swap with the ghost — and back, on drop —
                // must be instantaneous to read as one continuous row.
                .opacity(draggingID == id && draggedFrame != nil ? 0 : 1)
                .animation(nil, value: draggingID == id)
                .background(GeometryReader { proxy in
                    // Only report frames while a drag is actually active. Reporting on
                    // every scroll frame otherwise churns this preference (and the
                    // parent's @State via onPreferenceChange), which showed up as
                    // scroll jank / high CPU even when nothing was being dragged.
                    Color.clear.preference(key: RowFrameKey.self,
                                           value: draggingID != nil ? [id: proxy.frame(in: .named("reorder"))] : [:])
                })
        } else {
            content
        }
    }

    /// Rows between the dragged row's (vacated) slot and the cursor slide one
    /// slot toward the vacancy, opening the insertion gap at the cursor.
    private var shift: CGFloat {
        guard sectionActive, draggingID != nil, draggingID != id,
              let dragged = draggedFrame, let own = frames[id] else { return 0 }
        let slot = dragged.height + 2   // vacated space: dragged row + list spacing
        if own.midY > dragged.midY && own.midY < cursorY { return -slot }
        if own.midY < dragged.midY && own.midY > cursorY { return slot }
        return 0
    }
}

/// The drag session's AppKit side: window-level event tracking (file header №3)
/// and edge auto-scroll (№4).
@MainActor
final class ReorderAutoScroller: NSObject {
    weak var scrollView: NSScrollView?
    /// Re-fires the active reorder handler with the cursor's new content-space y.
    var onScroll: ((CGFloat) -> Void)?

    private var link: CADisplayLink?
    private var monitor: Any?
    private var cursorY: CGFloat = 0
    private var speed: CGFloat = 0             // points per second, positive = scroll down

    private static let zone: CGFloat = 44      // edge band that triggers scrolling
    private static let maxSpeed: CGFloat = 540 // points per second at full ramp

    /// True once `beginSession` has installed the drag's event monitor — the
    /// row's own gesture must stop feeding updates then (same events, but a
    /// second coordinate source would fight the monitor's).
    var sessionActive: Bool { monitor != nil }

    /// Take over drag tracking from the row's own DragGesture. That gesture
    /// lives on a lazy-stack row, and the stack removes the row from the
    /// hierarchy once its slot scrolls off-screen — the gesture dies with it,
    /// silently: no more updates, no `onEnded`, a stranded drag. A window-level
    /// event monitor doesn't care about the row's lifetime: it feeds the same
    /// drag updates and, crucially, always delivers the mouse-up.
    func beginSession(onDrag: @escaping (CGFloat) -> Void, onUp: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseUp {
                onUp()
            } else if let y = self?.contentY(event) {
                onDrag(y)
            }
            return event
        }
    }

    private func endSession() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The event's location in the scroll content's (top-down, flipped)
    /// coordinates — the same space the row gesture reports in.
    private func contentY(_ event: NSEvent) -> CGFloat? {
        guard let doc = scrollView?.documentView, event.window === doc.window else { return nil }
        return doc.convert(event.locationInWindow, from: nil).y
    }

    func update(cursorY y: CGFloat) {
        cursorY = y
        guard let clip = scrollView?.contentView else { return }
        let viewportY = y - clip.bounds.origin.y
        let height = clip.bounds.height
        if viewportY < Self.zone {
            speed = -Self.maxSpeed * (1 - max(viewportY, 0) / Self.zone)
        } else if viewportY > height - Self.zone {
            speed = Self.maxSpeed * (1 - max(height - viewportY, 0) / Self.zone)
        } else {
            speed = 0
        }
        if speed == 0 { stopLink() } else { startLink() }
    }

    func stop() {
        stopLink()
        endSession()
        onScroll = nil
    }

    private func startLink() {
        guard link == nil, let scrollView else { return }
        // Display-synced ticks (vs a Timer): the scroll advances exactly once per
        // frame, sized by the real frame duration — a free-running timer drifts
        // against the refresh rate and shows up as judder.
        let l = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        // .common so it keeps firing while the drag gesture tracks the mouse.
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, let doc = scrollView.documentView else { stopLink(); return }
        let clip = scrollView.contentView
        let dt = link.targetTimestamp - link.timestamp
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let target = min(max(clip.bounds.origin.y + speed * dt, 0), maxY)
        let delta = target - clip.bounds.origin.y
        guard delta != 0 else { stopLink(); return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        cursorY += delta
        onScroll?(cursorY)
    }
}

/// Hands the enclosing NSScrollView to a `ReorderAutoScroller`. Attach as a
/// `.background` of the scroll view's **content** (like `OverlayScrollerStyle`)
/// so `enclosingScrollView` resolves through the document-view hierarchy.
struct AutoScrollerCapture: NSViewRepresentable {
    let scroller: ReorderAutoScroller
    func makeNSView(context: Context) -> NSView { Capture(scroller: scroller) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Capture)?.scroller = scroller
    }

    private final class Capture: NSView {
        var scroller: ReorderAutoScroller
        init(scroller: ReorderAutoScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Defer a runloop: on insertion the enclosing scroll view isn't wired yet.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scroller.scrollView = self.enclosingScrollView
                }
            }
        }
    }
}
