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

    /// YouTube video id, for precise dedupe. Set at load time — read from the
    /// source-URL tag embedded in the file first (so it survives a rename),
    /// falling back to the `[id]` suffix in the file name. nil for hand-added /
    /// non-YouTube files.
    var videoID: String?

    var url: URL { id }

    // A YouTube id is 11 chars of [A-Za-z0-9_-], embedded in the file name as
    // "name [id]". Compiled once and shared read-only (safe despite Regex not
    // being Sendable), and type-checked at compile time.
    nonisolated(unsafe) private static let idRegex = /\[([A-Za-z0-9_-]{11})\]$/
    nonisolated(unsafe) private static let idSuffixRegex = /[ ]*\[[A-Za-z0-9_-]{11}\]$/

    /// Video id from a file's `name [id]` suffix, if present — the fallback when
    /// no source-URL tag is embedded.
    static func filenameVideoID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return name.firstMatch(of: idRegex).map { String($0.1) }
    }

    /// Falls back to the file name (minus the `[id]` suffix) when there's no title tag.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let name = id.deletingPathExtension().lastPathComponent
        return name.replacing(Self.idSuffixRegex, with: "")
    }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Best-effort YouTube video id straight from a URL string — no network, no
    /// yt-dlp — so a paste can be deduped against the library instantly. Returns
    /// nil for shapes we can't confidently parse (those fall back to yt-dlp).
    static func youtubeID(from urlString: String) -> String? {
        let string = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Any URL carrying a `v=ID` query item (watch?v=…, plus &list=/&t=).
        if let comps = URLComponents(string: string),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           v.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil {
            return v
        }
        // Short / embed / shorts / live forms: the id follows the path segment.
        if let match = string.firstMatch(of: /(?:youtu\.be\/|\/embed\/|\/shorts\/|\/live\/)([A-Za-z0-9_-]{11})/) {
            return String(match.1)
        }
        return nil
    }
}

extension Track {
    /// Read title / artist / artwork / duration from a file's metadata.
    static func load(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = ""
        var artist = ""
        var artworkData: Data?
        var duration: TimeInterval = 0
        var videoID: String?

        if let cmDuration = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(cmDuration)
            if !duration.isFinite { duration = 0 }
        }

        // One metadata pass reads the common fields AND the video id, so this
        // costs no more than the previous common-only load. The id is the source
        // URL yt-dlp embeds via --add-metadata (survives a file rename); the
        // file name's `[id]` suffix is the fallback.
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let string = try? await item.load(.stringValue)
                if let key = item.commonKey {
                    switch key {
                    case .commonKeyTitle:   if let string { title = string }
                    case .commonKeyArtist:  if let string { artist = string }
                    case .commonKeyArtwork: if let data = try? await item.load(.dataValue) { artworkData = data }
                    default: break
                    }
                }
                if videoID == nil, let string, let id = youtubeID(from: string) { videoID = id }
            }
        }
        if videoID == nil { videoID = filenameVideoID(url) }

        return Track(id: url, title: title, artist: artist,
                     duration: duration, artworkData: artworkData, videoID: videoID)
    }
}
