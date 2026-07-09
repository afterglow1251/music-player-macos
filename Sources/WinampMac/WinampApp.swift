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
    }
}

/// When launched as a bare SwiftPM binary (no .app bundle), macOS treats us as a
/// background process. Force a regular activation policy so the window comes to
/// the front with a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = AppIcon.make()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
