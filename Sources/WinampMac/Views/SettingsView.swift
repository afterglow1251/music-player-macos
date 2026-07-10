import SwiftUI

/// Inline settings panel that takes the artwork's place — so the visualizer
/// below stays visible and theme/EQ changes preview live while you tweak them.
struct SettingsView: View {
    @ObservedObject var controller: PlayerController
    let accent: Color
    let width: CGFloat
    let height: CGFloat
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("VISUALIZER THEME")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            themeGrid

            Spacer(minLength: 4)

            EqualizerView(controller: controller, accent: accent)
        }
        .padding(14)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08)))
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(PressableButtonStyle())
            .help("Close")
        }
    }

    private var themeGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 82), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(VisualizerTheme.all.enumerated()), id: \.offset) { index, theme in
                let selected = index == controller.themeIndex
                Button { controller.themeIndex = index } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [theme.colors.first ?? .green,
                                                          theme.colors[theme.colors.count / 2],
                                                          theme.colors.last ?? .red],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(width: 14, height: 14)
                        Text(theme.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? accent.opacity(0.18) : .white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(selected ? accent.opacity(0.7) : .clear, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle(hoverScale: 1.03))
            }
        }
    }
}
