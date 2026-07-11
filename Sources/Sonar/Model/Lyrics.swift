import Foundation

/// One timestamped line of a synced lyric.
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval   // seconds from the start of the track
    let text: String
}

/// Where a track's synced lyrics come from, and how they're parsed.
///
/// Lookup order: a sibling `.lrc` file next to the audio (so downloaded/edited
/// lyrics win and work offline), then LRCLIB — a free, keyless community lyrics
/// API matched on artist + title + **duration** (so the timestamps line up with
/// our exact copy). A hit from the network is cached to the sibling `.lrc`.
enum LyricsProvider {

    /// Fetch synced lyrics for a track, or nil if none are available.
    static func fetch(for track: Track) async -> [LyricLine]? {
        if let local = loadSibling(for: track.url) {
            return local
        }
        guard let lines = await fetchFromLRCLIB(track) else { return nil }
        cacheSibling(lines.raw, for: track.url)
        return lines.parsed
    }

    // MARK: Sibling .lrc file

    private static func siblingURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("lrc")
    }

    private static func loadSibling(for audio: URL) -> [LyricLine]? {
        let url = siblingURL(for: audio)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = parse(text)
        return lines.isEmpty ? nil : lines
    }

    private static func cacheSibling(_ raw: String, for audio: URL) {
        guard !raw.isEmpty else { return }
        try? raw.write(to: siblingURL(for: audio), atomically: true, encoding: .utf8)
    }

    // MARK: LRCLIB

    private static func fetchFromLRCLIB(_ track: Track) async -> (raw: String, parsed: [LyricLine])? {
        guard !track.displayTitle.isEmpty else { return nil }
        // Precise match first (clean tags), then a fuzzy search that tolerates the
        // messy "Artist - Title (feat…)" titles YouTube downloads carry.
        if let hit = await lrclibGet(track) { return hit }
        return await lrclibSearch(track)
    }

    /// Strict lookup: exact artist + title (+ duration). Best when the file's tags
    /// are clean; returns nil (404) when they aren't.
    private static func lrclibGet(_ track: Track) async -> (raw: String, parsed: [LyricLine])? {
        guard !track.artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.displayTitle),
        ]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        components?.queryItems = items
        guard let url = components?.url,
              let payload: LRCLIBRecord = await get(url),
              let synced = payload.syncedLyrics, !synced.isEmpty
        else { return nil }
        let parsed = parse(synced)
        return parsed.isEmpty ? nil : (synced, parsed)
    }

    /// Fuzzy fallback: full-text search, then pick the synced result whose duration
    /// is closest to ours (so a wrong-length remix doesn't win). Tries the cleaned
    /// title alone first — a YouTube title already holds the real "Artist - Title",
    /// and prepending a channel name (e.g. "2PacVEVO") only poisons the match — and
    /// only then falls back to an explicit artist + title query.
    private static func lrclibSearch(_ track: Track) async -> (raw: String, parsed: [LyricLine])? {
        for query in searchQueries(for: track) {
            guard var components = URLComponents(string: "https://lrclib.net/api/search") else { continue }
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url,
                  let results: [LRCLIBRecord] = await get(url) else { continue }

            let synced = results.filter { !($0.syncedLyrics ?? "").isEmpty }
            guard !synced.isEmpty else { continue }
            let best = track.duration > 0
                ? synced.min { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }!
                : synced[0]
            let raw = best.syncedLyrics!
            let parsed = parse(raw)
            if !parsed.isEmpty { return (raw, parsed) }
        }
        return nil
    }

    /// Candidate search queries in priority order: the noise-stripped title on its
    /// own, then artist + title when the artist adds something not already in the
    /// title. Deduped, empties dropped.
    private static func searchQueries(for track: Track) -> [String] {
        let title = track.displayTitle.replacing(noiseRegex, with: "")
            .trimmingCharacters(in: .whitespaces)
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        var queries = [title]
        if !artist.isEmpty, !title.localizedCaseInsensitiveContains(artist) {
            queries.append((artist + " " + title).trimmingCharacters(in: .whitespaces))
        }
        return queries.filter { !$0.isEmpty }.reduce(into: []) { acc, q in
            if !acc.contains(q) { acc.append(q) }
        }
    }

    // Parenthetical/bracket groups that are pure noise for matching (kept: "(feat…)").
    nonisolated(unsafe) private static let noiseRegex =
        /\s*[\(\[][^\)\]]*(?i:official|video|audio|lyrics?|visuali[sz]er|remaster|explicit|\bhd\b|\b4k\b|\bmv\b)[^\)\]]*[\)\]]/

    /// Shared GET → decode helper (UA header, 200-only, best-effort).
    private static func get<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("Sonar (macOS music player; github.com/afterglow1251/music-player-macos)",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return decoded
    }

    private struct LRCLIBRecord: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    // MARK: LRC parsing

    // `[mm:ss.xx]` or `[mm:ss]`; a line may carry several timestamps. Compiled once
    // and shared read-only (safe despite Regex not being Sendable).
    nonisolated(unsafe) private static let stampRegex = /\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/

    /// Parse an LRC document into timestamped lines, sorted by time. Metadata tags
    /// (`[ar:…]`, `[ti:…]`, …) carry no numeric time and are skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let stamps = line.matches(of: stampRegex)
            guard !stamps.isEmpty else { continue }

            // The lyric text is whatever follows the last timestamp on the line.
            let textStart = stamps.map(\.range.upperBound).max()!
            let content = line[textStart...].trimmingCharacters(in: .whitespaces)

            for stamp in stamps {
                let minutes = Double(stamp.1) ?? 0
                let seconds = Double(stamp.2) ?? 0
                let fraction = stamp.3.map { frac -> Double in
                    // "5" → .5, "05" → .05, "050" → .050
                    (Double(frac) ?? 0) / pow(10, Double(frac.count))
                } ?? 0
                out.append(LyricLine(time: minutes * 60 + seconds + fraction, text: content))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Index of the line active at `time` (the last line whose stamp has passed),
    /// or nil before the first line.
    static func activeIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        var index = 0
        for (i, line) in lines.enumerated() where line.time <= time { index = i }
        return index
    }
}
