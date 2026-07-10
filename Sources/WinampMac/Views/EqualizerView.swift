import SwiftUI

/// 10-band graphic equalizer with vertical sliders and presets.
struct EqualizerView: View {
    @ObservedObject var controller: PlayerController
    let accent: Color

    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private var engine: AudioEngine { controller.engine }

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<10, id: \.self) { i in
                    EQBandSlider(
                        gain: Binding(get: { engine.eqGains[i] },
                                      set: { engine.eqGains[i] = $0 }),
                        label: labels[i],
                        accent: accent,
                        enabled: engine.eqEnabled
                    )
                }
            }
            .frame(height: 96)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { engine.eqEnabled.toggle() } label: {
                Text(engine.eqEnabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(engine.eqEnabled ? .black : .white.opacity(0.6))
                    .frame(width: 36, height: 18)
                    .background(Capsule().fill(engine.eqEnabled ? accent : .white.opacity(0.1)))
            }
            .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
            Text("EQUALIZER")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Menu {
                ForEach(EQPreset.all) { preset in
                    Button(preset.name) { controller.applyEQPreset(preset) }
                }
            } label: {
                Text("Presets")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// A single EQ band: a native macOS slider (same look as the volume slider)
/// rotated to be vertical. Gain range -12…+12 dB.
private struct EQBandSlider: View {
    @Binding var gain: Float
    let label: String
    let accent: Color
    let enabled: Bool

    private let length: CGFloat = 76

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { Double(gain) }, set: { gain = Float($0) }),
                   in: -12...12)
                .controlSize(.mini)
                .tint(enabled ? accent : .gray)
                .frame(width: length)                 // horizontal length before rotating
                .rotationEffect(.degrees(-90))        // → vertical
                .frame(width: 22, height: length)     // reserve the vertical space
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
