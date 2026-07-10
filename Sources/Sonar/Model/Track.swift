import Foundation
import AVFoundation

/// One audio file in the library, with its ID3 metadata already read.
///
/// Artwork is kept as raw `Data` (not `NSImage`) so `Track` stays `Sendable`
/// and can cross actor boundaries; the view builds the image on demand.
struct Track: Identifiable, Hashable, Sendable {
    let id: URL
    var title: String
    var artist: String
    var duration: TimeInterval
    var artworkData: Data?

    var url: URL { id }

    // A YouTube id is 11 chars of [A-Za-z0-9_-], embedded in the file name as
    // "name [id]". Compiled once and shared read-only (safe despite Regex not
    // being Sendable), and type-checked at compile time.
    nonisolated(unsafe) private static let idRegex = /\[([A-Za-z0-9_-]{11})\]$/
    nonisolated(unsafe) private static let idSuffixRegex = /[ ]*\[[A-Za-z0-9_-]{11}\]$/

    /// The embedded YouTube video id, used to detect duplicates precisely.
    var videoID: String? {
        let name = id.deletingPathExtension().lastPathComponent
        return name.firstMatch(of: Self.idRegex).map { String($0.1) }
    }

    /// Falls back to the file name (minus the `[id]` suffix) when there's no title tag.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let name = id.deletingPathExtension().lastPathComponent
        return name.replacing(Self.idSuffixRegex, with: "")
    }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Track {
    /// Read title / artist / artwork / duration from a file's metadata.
    static func load(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = ""
        var artist = ""
        var artworkData: Data?
        var duration: TimeInterval = 0

        if let cmDuration = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(cmDuration)
            if !duration.isFinite { duration = 0 }
        }

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue) { title = value }
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue) { artist = value }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) { artworkData = data }
                default:
                    break
                }
            }
        }

        return Track(id: url, title: title, artist: artist,
                     duration: duration, artworkData: artworkData)
    }
}
