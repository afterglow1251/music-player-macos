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
        } else if let percent = trailingPercent {
            // "Downloading 5%" → reserve the width of the widest counter and lay
            // the real text over it, left-aligned, so the number stays tight to
            // the label while nothing reflows as it climbs 5 → 43 → 100.
            Text(percent.prefix + "000%")
                .monospacedDigit()
                .hidden()
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        Text(percent.prefix)
                        Text(percent.digits).monospacedDigit()
                        Text("%")
                    }
                }
        } else {
            Text(status)
        }
    }

    /// Split a "…NN%" status into its leading text and the digit run, so the
    /// number can live in a steady slot. Nil for any status not ending in "N%".
    private var trailingPercent: (prefix: String, digits: String)? {
        guard status.hasSuffix("%") else { return nil }
        let body = status.dropLast()                       // drop "%"
        let digits = String(body.reversed().prefix { $0.isNumber }.reversed())
        guard !digits.isEmpty else { return nil }
        return (String(body.dropLast(digits.count)), digits)
    }
}
