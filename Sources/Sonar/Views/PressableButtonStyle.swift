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
