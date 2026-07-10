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
    var color: Color = .white
    var speed: Double = 35            // points per second
    private let spacing: CGFloat = 44 // gap between the repeated copies

    private var nsFont: NSFont { .systemFont(ofSize: fontSize, weight: bold ? .bold : .regular) }
    private var uiFont: Font { .system(size: fontSize, weight: bold ? .bold : .regular) }

    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: nsFont]).width
    }
    private var lineHeight: CGFloat { ceil(nsFont.ascender - nsFont.descender) + 2 }

    var body: some View {
        GeometryReader { geo in
            let overflowing = textWidth > geo.size.width + 1
            Group {
                if overflowing {
                    TimelineView(.animation) { tl in
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
