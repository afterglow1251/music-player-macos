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
    var album: String
    var duration: TimeInterval
    var artworkData: Data?

    /// Extended tags, best-effort. `year` is the 4-digit release year; `trackNumber`
    /// is the position within its album (nil when the tag is absent). These drive
    /// album grouping and metadata sorting.
    var year: Int?
    var trackNumber: Int?

    /// When the file landed in the library folder — the OS "date added" (falling
    /// back to creation date). Backs the "recently added" sort. nil if unreadable.
    var dateAdded: Date?

    /// YouTube video id, for precise dedupe. Set at load time — read from the
    /// source-URL tag embedded in the file first (so it survives a rename),
    /// falling back to the `[id]` suffix in the file name. nil for hand-added /
    /// non-YouTube files.
    var videoID: String?

    var url: URL { id }

    /// The YouTube watch URL this track was downloaded from, reconstructed from
    /// its `videoID`. nil for hand-added / non-YouTube files — the caller uses
    /// this to decide whether to offer an "Open on YouTube" affordance.
    var youtubeURL: URL? {
        guard let videoID else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

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
        var album = ""
        var artworkData: Data?
        var duration: TimeInterval = 0
        var year: Int?
        var trackNumber: Int?
        var videoID: String?

        // Date added: the OS "added to directory" date if the volume records it,
        // else the file's creation date. Read cheaply from the URL, no asset load.
        let dateAdded = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey]))
            .flatMap { $0.addedToDirectoryDate ?? $0.creationDate }

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
                    case .commonKeyTitle:        if let string { title = string }
                    case .commonKeyArtist:       if let string { artist = string }
                    case .commonKeyAlbumName:    if let string { album = string }
                    case .commonKeyArtwork:      if let data = try? await item.load(.dataValue) { artworkData = data }
                    case .commonKeyCreationDate: if year == nil, let string { year = releaseYear(from: string) }
                    default: break
                    }
                }
                // Track number lives in format-specific tags (ID3 TRCK, iTunes trkn),
                // not the common key set — match it by identifier. Values come as a
                // number or a "3/12" string; take the leading integer either way.
                if trackNumber == nil,
                   item.identifier == .id3MetadataTrackNumber || item.identifier == .iTunesMetadataTrackNumber {
                    if let number = try? await item.load(.numberValue) {
                        trackNumber = number.intValue
                    } else if let string {
                        trackNumber = Int(string.prefix { $0.isNumber })
                    }
                }
                if videoID == nil, let string, let id = youtubeID(from: string) { videoID = id }
            }
        }
        if videoID == nil { videoID = filenameVideoID(url) }

        return Track(id: url, title: title, artist: artist, album: album,
                     duration: duration, artworkData: artworkData,
                     year: year, trackNumber: trackNumber, dateAdded: dateAdded,
                     videoID: videoID)
    }

    /// The leading 4-digit year out of a tag value like "2011" or "2011-05-03".
    private static func releaseYear(from string: String) -> Int? {
        string.firstMatch(of: /(\d{4})/).map { Int($0.1) } ?? nil
    }
}
