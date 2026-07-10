import SwiftUI

/// Status text whose trailing "…" animates as 1→2→3 dots, so an indeterminate
/// step (e.g. "Preparing…") looks alive rather than frozen.
struct AnimatedStatusText: View {
    let status: String

    var body: some View {
        if status.hasSuffix("…") {
            // "Loading" stays put; only the dots cycle inside a fixed-width slot.
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3 + 1
                HStack(spacing: 0) {
                    Text(status.dropLast())
                    Text(String(repeating: ".", count: dots))
                        .frame(width: 12, alignment: .leading)
                }
            }
        } else {
            Text(status)
        }
    }
}

/// A button style that reacts to hover and press: it brightens and grows a touch
/// on hover, and dips down when pressed — small springy feedback for liveliness.
struct PressableButtonStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.10
    var pressScale: CGFloat = 0.90

    func makeBody(configuration: Configuration) -> some View {
        Reactive(configuration: configuration, hoverScale: hoverScale, pressScale: pressScale)
    }

    private struct Reactive: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        let pressScale: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(hovering ? 0.10 : 0)
                .scaleEffect(configuration.isPressed ? pressScale : (hovering ? hoverScale : 1.0))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
                .animation(.spring(response: 0.18, dampingFraction: 0.5), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// One row in the library list. Highlights on hover and when it's the current
/// track, so the playlist feels interactive.
struct TrackRowView: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let durationText: String
    let onTap: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void
    private let accent = Theme.accent

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent && isPlaying ? "speaker.wave.2.fill" : "music.note")
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? accent : .white.opacity(0.4))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // On hover show a trash button; otherwise the duration. Both live in a
            // fixed-width slot so nothing shifts; the button scales around its own
            // (small, centered) frame so it grows in place instead of drifting.
            Group {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.9))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Delete (move to Trash)")
                } else {
                    Text(durationText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Play", action: onTap)
            Button("Play Next", action: onPlayNext)
            Button("Add to Queue", action: onAddToQueue)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        if isCurrent { return accent.opacity(0.16) }
        return hovering ? .white.opacity(0.07) : .clear
    }
}

/// One row in the "Up Next" queue — compact, numbered, with a remove button on hover.
struct QueueRowView: View {
    let track: Track
    let position: Int
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 16)
            Text(track.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            // The button always occupies the slot (fades in on hover) so the row
            // keeps a constant height and never shifts — same as the library rows.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(PressableButtonStyle())
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Remove from queue")
            .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
