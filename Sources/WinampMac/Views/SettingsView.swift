import SwiftUI

/// Inline settings panel that takes the artwork's place — the visualizer below
/// stays visible so theme/EQ changes preview live. Equalizer is on top (most
/// used); themes are a compact swatch row that reveals names on hover.
struct SettingsView: View {
    @ObservedObject var controller: PlayerController
    let accent: Color
    let width: CGFloat
    let height: CGFloat

    @State private var customMinutes = ""
    @State private var hoveredTheme: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EqualizerView(controller: controller, accent: accent)
                    sleepSection
                    themeSection
                }
                .padding(5)   // room for hover-scaled buttons
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08)))
    }

    // MARK: Sleep timer (compact)

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("SLEEP TIMER")
                if let remaining = controller.sleepRemaining {
                    Text(timeString(remaining))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                } else if controller.sleepMode == .endOfTrack {
                    Text("· end of track")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            HStack(spacing: 5) {
                sleepChip("Off", active: controller.sleepMode == .off) { controller.setSleep(.off) }
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    sleepChip("\(m)", active: controller.sleepMode == .timer(minutes: m)) {
                        controller.setSleep(.timer(minutes: m))
                    }
                }
                sleepChip("End", active: controller.sleepMode == .endOfTrack) {
                    controller.setSleep(.endOfTrack)
                }
                HStack(spacing: 3) {
                    SteadyTextField(placeholder: "min", text: $customMinutes,
                                    font: .system(size: 10), onSubmit: applyCustom)
                        .frame(width: 30)
                    Button(action: applyCustom) {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 12))
                            .foregroundStyle(accent)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06)))
            }
        }
    }

    private func sleepChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? .black : .white.opacity(0.7))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(active ? accent : .white.opacity(0.06)))
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
    }

    // MARK: Themes (compact swatches, name on hover)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("VISUALIZER THEME")
                Text("· \(VisualizerTheme.all[hoveredTheme ?? controller.themeIndex].name)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            HStack(spacing: 7) {
                ForEach(Array(VisualizerTheme.all.enumerated()), id: \.offset) { index, theme in
                    let selected = index == controller.themeIndex
                    Button { controller.themeIndex = index } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [theme.colors.first ?? .green,
                                                          theme.colors[theme.colors.count / 2],
                                                          theme.colors.last ?? .red],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white, lineWidth: selected ? 2 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: selected ? 0 : 1))
                    }
                    .buttonStyle(PressableButtonStyle(hoverScale: 1.22))
                    .onHover { hoveredTheme = $0 ? index : nil }
                    .help(theme.name)
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
    }

    private func applyCustom() {
        if let minutes = Int(customMinutes.trimmingCharacters(in: .whitespaces)), minutes > 0 {
            controller.setSleep(.timer(minutes: minutes))
            customMinutes = ""
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
