import SwiftUI

/// A borderless text field with a **static** placeholder that never jitters.
///
/// AppKit's native placeholder shifts ~1px between the empty/edited states; here
/// we draw our own placeholder and disable the focus ring, so it stays put.
struct SteadyTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .system(size: 12)
    var placeholderColor: Color = .white.opacity(0.4)
    var textColor: Color = .white
    var onSubmit: () -> Void = {}
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(placeholderColor)
                    .allowsHitTesting(false)
            }
            field
        }
    }

    @ViewBuilder private var field: some View {
        let base = TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(textColor)
            .focusEffectDisabled()
            .onSubmit(onSubmit)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}
