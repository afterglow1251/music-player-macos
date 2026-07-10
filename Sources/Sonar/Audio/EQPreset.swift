import Foundation

/// Named 10-band equalizer presets (gains in dB, low → high frequency).
struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat",    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass",    gains: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble",  gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        EQPreset(name: "Rock",    gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        EQPreset(name: "Pop",     gains: [-1, 0, 2, 4, 4, 3, 1, 0, -1, -1]),
        EQPreset(name: "Jazz",    gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        EQPreset(name: "Vocal",   gains: [-2, -2, -1, 2, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Loud",    gains: [6, 4, 0, 0, -1, 0, 0, 0, 4, 6]),
    ]

    static let flat = all[0]
}
