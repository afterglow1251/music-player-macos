import Foundation
import MediaPlayer
import AppKit

/// Bridges the player to macOS: publishes "Now Playing" info (Control Center,
/// lock screen) and routes the hardware media keys / remote commands back to us.
@MainActor
final class NowPlayingController {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    init() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }

        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
         center.nextTrackCommand, center.previousTrackCommand].forEach { $0.isEnabled = true }
    }

    /// Push the current track + playback state to the system.
    func update(track: Track?, isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? "Sonar" : track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let data = track.artworkData, let image = NSImage(data: data) {
            let size = image.size
            // MediaPlayer calls this handler on a background queue, so it must NOT
            // be main-actor isolated. Build the image from `Data` (Sendable) inside
            // an @Sendable closure instead of capturing the NSImage.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                NSImage(data: data) ?? NSImage(size: size)
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
