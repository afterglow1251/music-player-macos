import SwiftUI

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
    let accent: Color
    let durationText: String
    let onTap: () -> Void
    let onDelete: () -> Void

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
            Button("Delete", role: .destructive, action: onDelete)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        if isCurrent { return accent.opacity(0.16) }
        return hovering ? .white.opacity(0.07) : .clear
    }
}
