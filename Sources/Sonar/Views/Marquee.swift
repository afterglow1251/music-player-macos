import SwiftUI
import AppKit

/// Horizontally scrolling text — like a classic player's title bar. Scrolls only when the
/// text is wider than its container; otherwise it sits still.
///
/// The text width is measured mathematically from the font (not via a hidden
/// SwiftUI view), so it never expands the surrounding layout.
struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 15
    var bold: Bool = true
    /// Overrides `bold` when set — lets callers ask for intermediate weights
    /// (e.g. the menu-bar panel's `.semibold` title) instead of only bold/regular.
    var weight: Font.Weight? = nil
    var color: Color = .white
    var speed: Double = 35            // points per second
    /// Freezes the scroll — set while the host window is occluded/minimized so
    /// the per-frame TimelineView doesn't animate for nobody.
    var paused: Bool = false
    private let spacing: CGFloat = 44 // gap between the repeated copies

    private var resolvedWeight: Font.Weight { weight ?? (bold ? .bold : .regular) }
    private var nsFont: NSFont { .systemFont(ofSize: fontSize, weight: resolvedWeight.nsWeight) }
    private var uiFont: Font { .system(size: fontSize, weight: resolvedWeight) }

    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: nsFont]).width
    }
    private var lineHeight: CGFloat { ceil(nsFont.ascender - nsFont.descender) + 2 }

    var body: some View {
        GeometryReader { geo in
            let overflowing = textWidth > geo.size.width + 1
            Group {
                if overflowing {
                    // Capped at 30fps like the visualizer/breathing cover — at
                    // 35 pt/s that's ~1.2 pt a frame, indistinguishable from a
                    // display-rate scroll at a quarter of the frame work.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                        let period = (textWidth + spacing) / speed
                        let phase = period > 0
                            ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                            : 0
                        HStack(spacing: spacing) { label; label }
                            .offset(x: -CGFloat(phase) * (textWidth + spacing))
                    }
                    .mask(edgeFade)
                } else {
                    label
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: lineHeight)
    }

    private var label: some View {
        Text(text).font(uiFont).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.94),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

private extension Font.Weight {
    /// The matching AppKit weight, so the mathematical width measurement uses the
    /// same font as the rendered SwiftUI `Text`.
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
