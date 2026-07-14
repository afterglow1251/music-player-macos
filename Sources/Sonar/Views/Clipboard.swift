import SwiftUI
import AppKit

extension View {
    /// Make this text clickable to copy `value` to the clipboard. Adds no visible
    /// button — the affordance is a pointing-hand cursor and tooltip on hover, and
    /// a brief "Copied ✓" flash on click. Used for the now-playing title/artist so
    /// they can be lifted to the clipboard without cluttering the strip.
    func copyOnClick(_ value: String, help: String = "Click to copy", enabled: Bool = true) -> some View {
        modifier(CopyOnClick(value: value, help: help, enabled: enabled))
    }
}

/// Puts `string` on the general pasteboard. Central so every copy affordance
/// (now-playing strip, row context menus) behaves identically.
@MainActor func copyToClipboard(_ string: String) {
    guard !string.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

/// Opens a URL in the user's default browser.
@MainActor func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}

/// Click-to-copy behaviour for a text view: a pointing-hand cursor + tooltip on
/// hover, and a brief "Copied ✓" pill on click. No resting chrome, so it stays
/// out of the way until the pointer lands on the text.
private struct CopyOnClick: ViewModifier {
    let value: String
    let help: String
    var enabled: Bool = true

    @State private var copied = false
    @State private var flashTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if enabled {
            copyable(content)
        } else {
            content
        }
    }

    private func copyable(_ content: Content) -> some View {
        content
            // On copy the label itself flashes to a "Copied ✓" pill in place, then
            // fades back — so the confirmation never lands on top of neighbouring
            // text. Hidden (not removed) so the row keeps its height/position.
            .opacity(copied ? 0 : 1)
            .contentShape(Rectangle())
            .onHover { inside in
                // Hint that the text is interactive without a visible button.
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture {
                guard !value.isEmpty else { return }
                copyToClipboard(value)
                flashTask?.cancel()
                withAnimation(.easeOut(duration: 0.12)) { copied = true }
                flashTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(850))
                    if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { copied = false } }
                }
            }
            .overlay(alignment: .leading) {
                if copied {
                    CopiedBadge()
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .help(help)
    }
}

/// The little "Copied ✓" pill that momentarily replaces the clicked text.
private struct CopiedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
            Text("Copied")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .fixedSize()
    }
}
