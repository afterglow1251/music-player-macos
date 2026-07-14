import Foundation

/// "00:34"-style clock readout used by the seek bars, time labels and the sleep
/// timer. `padMinutes: false` gives the mini-player's compact "3:12" form.
func clockTimeString(_ t: TimeInterval, padMinutes: Bool = true) -> String {
    guard t.isFinite, t >= 0 else { return padMinutes ? "00:00" : "0:00" }
    let total = Int(t)
    return String(format: padMinutes ? "%02d:%02d" : "%d:%02d", total / 60, total % 60)
}
