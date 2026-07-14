import AppKit
import SwiftUI

/// Publishes whether the main player window can actually be seen — not fully
/// covered by other windows, not miniaturized, not parked on another Space.
/// The per-frame eye candy (visualizer, breathing cover, marquee) pauses on
/// this, so listening with the window out of sight costs no rendering at all.
///
/// Refreshes on window notifications from ANY window (they're cheap and the
/// lookup is idempotent) rather than capturing the posting window — the
/// SwiftUI `Window` scene owns its `NSWindow`, which doesn't exist yet when a
/// view inside it creates this monitor. Observers are never unregistered: the
/// monitor is `PlayerWindow` state, alive for the app's lifetime (the same
/// deal `MenuBarController` makes).
@MainActor
final class WindowOcclusionMonitor: ObservableObject {
    @Published private(set) var isVisible = true

    init() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "player" })
        else { return }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        if visible != isVisible { isVisible = visible }
    }
}
