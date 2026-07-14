import SwiftUI

/// A quick horizontal wiggle — flags "this is already here" without words. Drive
/// `animatableData` 0→1 (one burst = `shakes` bumps) with an animation.
///
/// Rightward-only: the chip lives in a clipping horizontal ScrollView, so a
/// symmetric shake would clip its (input-aligned) left edge. Nudging only to the
/// right keeps that edge fixed and never crosses the clip.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = Double(animatableData) * .pi * 2 * Double(shakes)
        let dx = travel * CGFloat((1 - cos(phase)) / 2)   // smooth 0→travel→0, ≥ 0
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
