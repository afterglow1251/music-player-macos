import SwiftUI

/// One row in the "Up Next" queue — compact, numbered, with a remove button on hover.
struct QueueRowView: View {
    let track: Track
    let position: Int
    let onRemove: () -> Void
    var reorderID: String? = nil
    var isDragging: Bool = false
    /// See TrackRowView.dragActive — hush hover flashes while a drag scrolls the list.
    var dragActive: Bool = false
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    var onReorderEnded: () -> Void = {}

    @State private var hovering = false

    private var hover: Bool { hovering && (!dragActive || isDragging) }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 16)
            // Two lines — title over a muted artist — matching library/playlist rows.
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if reorderID != nil {
                    DragDots()
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 11, height: 18)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .named("reorder"))
                                .onChanged { onReorderChanged($0.location.y) }
                                .onEnded { _ in onReorderEnded() }
                        )
                        .help("Drag to reorder")
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Remove from queue")
            }
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            .frame(width: reorderID == nil ? 24 : 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isDragging ? Color(white: 0.16) : (hover ? Color.white.opacity(0.06) : .clear)))
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: isDragging ? .black.opacity(0.45) : .clear,
                radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Queue", role: .destructive, action: onRemove)
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
