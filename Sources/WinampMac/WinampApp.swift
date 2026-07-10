import SwiftUI
import AppKit

@main
struct WinampApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Winamp Mac", id: "player") {
            PlayerWindow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Standard macOS "Settings…" (⌘,) toggles the inline settings panel.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .toggleSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let toggleSettings = Notification.Name("WinampMac.toggleSettings")
}

/// When launched as a bare SwiftPM binary (no .app bundle), macOS treats us as a
/// background process. Force a regular activation policy so the window comes to
/// the front with a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = AppIcon.make()
        installClickToDismissFocus()
    }

    /// Any left-click that isn't on a text field drops the keyboard focus — so
    /// clicking anywhere (list, buttons, empty space) unfocuses the URL/search field.
    private func installClickToDismissFocus() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Extract Sendable values (NSWindow is main-actor → Sendable; point is
            // a value type) and finish on the main actor.
            let window = event.window
            let location = event.locationInWindow
            Task { @MainActor in
                guard let window else { return }
                let hit = window.contentView?.hitTest(location)
                if !AppDelegate.isTextEditingView(hit) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    /// Walks up the view hierarchy to see if the click landed in a text field.
    @MainActor
    private static func isTextEditingView(_ view: NSView?) -> Bool {
        var current = view
        while let node = current {
            if node is NSTextView || node is NSTextField { return true }
            current = node.superview
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
