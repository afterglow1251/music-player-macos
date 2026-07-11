import SwiftUI

/// App-wide design tokens — the single source of truth so a brand change is a
/// one-line edit instead of hunting hardcoded values across the UI.
enum Theme {
    /// The Sonar accent (green), used for highlights, the play button, sliders…
    static let accent = Color(red: 0.29, green: 0.87, blue: 0.42)

    /// The favorite/like accent — a warm rose for heart marks, kept distinct from
    /// the green accent so a favorited track reads instantly.
    static let favorite = Color(red: 1.0, green: 0.35, blue: 0.45)
}
