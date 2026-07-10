import Foundation

/// Typed wrapper over `UserDefaults`. One place owns every key **and** its type,
/// so a read and a write can never disagree, and a mistyped key is a compile
/// error rather than a silent runtime bug.
final class Preferences {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key: String {
        case volume, eqGains, eqEnabled, shuffle, repeatMode
        case themeName, lastTrack, lastPosition
    }

    var volume: Float? {
        get { defaults.object(forKey: Key.volume.rawValue) as? Float }
        set { defaults.set(newValue, forKey: Key.volume.rawValue) }
    }

    /// Stored as `[Double]` (UserDefaults has no Float array), exposed as `[Float]`.
    var eqGains: [Float]? {
        get { (defaults.array(forKey: Key.eqGains.rawValue) as? [Double])?.map(Float.init) }
        set { defaults.set(newValue?.map(Double.init), forKey: Key.eqGains.rawValue) }
    }

    var eqEnabled: Bool? {
        get { defaults.object(forKey: Key.eqEnabled.rawValue) as? Bool }
        set { defaults.set(newValue, forKey: Key.eqEnabled.rawValue) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle.rawValue) }
        set { defaults.set(newValue, forKey: Key.shuffle.rawValue) }
    }

    var repeatMode: RepeatMode {
        get { RepeatMode(rawValue: defaults.integer(forKey: Key.repeatMode.rawValue)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.repeatMode.rawValue) }
    }

    /// Theme is persisted by **name** (stable) rather than array index.
    var themeName: String? {
        get { defaults.string(forKey: Key.themeName.rawValue) }
        set { defaults.set(newValue, forKey: Key.themeName.rawValue) }
    }

    var lastTrack: String? {
        get { defaults.string(forKey: Key.lastTrack.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastTrack.rawValue) }
    }

    var lastPosition: Double {
        get { defaults.double(forKey: Key.lastPosition.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastPosition.rawValue) }
    }
}
