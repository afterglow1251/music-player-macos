import SwiftUI
import AppKit

/// A small, dark, rounded tooltip label — Spotify-style. An optional `hotkey`
/// (e.g. "⌘▶") renders as its own keycap chip(s) instead of trailing plain
/// text, so the shortcut reads as "press this key" rather than more label copy.
struct TooltipLabel: View {
    let text: String
    var hotkey: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if let hotkey {
                // One combo, one keycap — every glyph in `hotkey` shares a single
                // rounded rect rather than each getting its own chip, since they
                // together spell one shortcut (e.g. ⌘▶), not a sequence of keys.
                HStack(spacing: 3) {
                    ForEach(Array(Self.hotkeyTokens(hotkey).enumerated()), id: \.offset) { _, token in
                        keycapGlyph(token)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(minHeight: 15)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.16)))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .fixedSize()
    }

    /// A keycap's contents. Unicode arrow/command glyphs sit off-center inside
    /// their own advance box in most fonts, so use the equivalent SF Symbol —
    /// its bounding box is drawn to be visually centered — and fall back to
    /// plain text only for glyphs without one.
    @ViewBuilder
    private func keycapGlyph(_ token: String) -> some View {
        switch token {
        case "⌘": Image(systemName: "command").font(.system(size: 9, weight: .semibold))
        case "▶": Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8, weight: .semibold))
        case "◀": Image(systemName: "arrowtriangle.left.fill").font(.system(size: 8, weight: .semibold))
        default: Text(token).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    /// Split a hotkey string into keycap tokens: known symbol glyphs (⌘, ◀, ▶,
    /// …) become their own token, while any run of other characters (e.g. the
    /// word "Space") stays together as one token instead of being torn into
    /// individual letters.
    private static let symbolGlyphs: Set<Character> = ["⌘", "▶", "◀"]

    private static func hotkeyTokens(_ hotkey: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for char in hotkey {
            if symbolGlyphs.contains(char) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(char))
            } else {
                word.append(char)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }
}

extension View {
    /// Show a tidy custom tooltip above this view on hover (replaces the slow,
    /// native yellow `.help` tooltip with a Spotify-style one). `hotkey`, if
    /// given, renders as keycap chips (e.g. "⌘▶") instead of inline text.
    func tooltip(_ text: String, hotkey: String? = nil) -> some View {
        modifier(TooltipModifier(text: text, hotkey: hotkey))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    var hotkey: String? = nil
    @State private var show = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                delay?.cancel()
                if hovering {
                    delay = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { show = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { show = false }
                }
            }
            // Once a button opens a Menu, AppKit enters menu-tracking mode and
            // SwiftUI stops delivering hover-out events, so `show` would otherwise
            // stay true and the tooltip lingers under/around the open menu. Force
            // it closed as soon as any menu starts tracking (and on app resign-
            // active, for the same reason).
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                dismiss()
            }
            .overlay(alignment: .top) {
                if show {
                    TooltipLabel(text: text, hotkey: hotkey)
                        .offset(y: -30)
                        .allowsHitTesting(false)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
    }

    private func dismiss() {
        delay?.cancel()
        show = false
    }
}
