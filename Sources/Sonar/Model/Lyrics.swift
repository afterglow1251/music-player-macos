import Foundation

/// One timestamped line of a synced lyric.
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval   // seconds from the start of the track
    let text: String
}

/// Where a track's synced lyrics come from, and how they're parsed.
///
/// Lookup order: a cached `.lrc` in the hidden `.sonar/` folder beside the audio
/// (so downloaded lyrics work offline), then LRCLIB — a free, keyless community
/// lyrics API matched on artist + title + **duration** (so the timestamps line up
/// with our exact copy). A hit from the network is cached back to `.sonar/`.
enum LyricsProvider {

    /// Fetch synced lyrics for a track, or nil if none are available.
    static func fetch(for track: Track) async -> [LyricLine]? {
        if let local = loadCache(for: track.url) {
            return local
        }
        guard let lines = await fetchFromLRCLIB(track) else { return nil }
        writeCache(lines.raw, for: track.url)
        return lines.parsed
    }

    // MARK: On-disk cache (hidden `.sonar/` folder beside the audio)

    /// The cache file for a track: `<audio dir>/.sonar/<audio filename>.lrc`.
    /// A hidden per-folder subdirectory keeps the music folder itself clean while
    /// the cache still travels with the library and works offline. Keying on the
    /// full filename (extension included) avoids collisions between same-named
    /// tracks of different formats.
    private static func cacheURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent()
            .appendingPathComponent(".sonar", isDirectory: true)
            .appendingPathComponent(audio.lastPathComponent)
            .appendingPathExtension("lrc")
    }

    private static func loadCache(for audio: URL) -> [LyricLine]? {
        guard let text = try? String(contentsOf: cacheURL(for: audio), encoding: .utf8)
        else { return nil }
        let lines = parse(text)
        return lines.isEmpty ? nil : lines
    }

    private static func writeCache(_ raw: String, for audio: URL) {
        guard !raw.isEmpty else { return }
        let url = cacheURL(for: audio)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? raw.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: LRCLIB

    private static func fetchFromLRCLIB(_ track: Track) async -> (raw: String, parsed: [LyricLine])? {
        guard !track.displayTitle.isEmpty else { return nil }

        // 1. Exact /api/get on the file's own tags (matches artist+title server-side).
        if !track.artist.isEmpty,
           let hit = await lrclibGetExact(artist: track.artist, title: track.displayTitle,
                                          duration: track.duration) {
            return hit
        }
        // 2. YouTube titles pack the real "Artist - Title" into one field — split it
        //    out and do an exact /api/get on those clean fields.
        if let (artist, title) = parseArtistTitle(from: track.displayTitle),
           let hit = await lrclibGetExact(artist: artist, title: title, duration: track.duration) {
            return hit
        }
        // 3. Last resort: fuzzy search, but only ACCEPT a result that verifiably
        //    matches this track. Better no lyrics than someone else's lyrics.
        return await lrclibSearch(track)
    }

    /// Exact lookup by artist + title. Tries with the duration first (LRCLIB's most
    /// precise match), then without it, so a track whose length differs slightly from
    /// LRCLIB's copy still resolves. Exact on artist+title, so it never mis-matches.
    private static func lrclibGetExact(artist: String, title: String,
                                       duration: TimeInterval) async -> (raw: String, parsed: [LyricLine])? {
        for includeDuration in [true, false] where !(includeDuration && duration <= 0) {
            guard var components = URLComponents(string: "https://lrclib.net/api/get") else { continue }
            var items = [
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "track_name", value: title),
            ]
            if includeDuration, duration > 0 {
                items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
            }
            components.queryItems = items
            guard let url = components.url,
                  let payload: LRCLIBRecord = await get(url),
                  let synced = payload.syncedLyrics, !synced.isEmpty else { continue }
            let parsed = parse(synced)
            if !parsed.isEmpty { return (synced, parsed) }
        }
        return nil
    }

    /// Fuzzy fallback: full-text search, keeping only results that pass a confidence
    /// gate (duration within a few seconds AND the title/artist words actually match).
    /// Among the survivors, the closest duration wins. If nothing qualifies → nil.
    private static func lrclibSearch(_ track: Track) async -> (raw: String, parsed: [LyricLine])? {
        for query in searchQueries(for: track) {
            guard var components = URLComponents(string: "https://lrclib.net/api/search") else { continue }
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url,
                  let results: [LRCLIBRecord] = await get(url) else { continue }

            let candidates = results.filter {
                !($0.syncedLyrics ?? "").isEmpty
                    && isConfidentMatch(title: $0.trackName ?? "", artist: $0.artistName ?? "",
                                        duration: $0.duration, track: track)
            }
            guard !candidates.isEmpty else { continue }
            let best = track.duration > 0
                ? candidates.min { abs(($0.duration ?? .greatestFiniteMagnitude) - track.duration)
                                 < abs(($1.duration ?? .greatestFiniteMagnitude) - track.duration) }!
                : candidates[0]
            if let raw = best.syncedLyrics {
                let parsed = parse(raw)
                if !parsed.isEmpty { return (raw, parsed) }
            }
        }
        return nil
    }

    // MARK: Match confidence

    /// Whether a search result is really *this* track. Rejects wrong-song matches
    /// (different length, or a title whose words we don't have) so a fuzzy search
    /// can't surface an unrelated song's lyrics.
    private static func isConfidentMatch(title candTitle: String, artist candArtist: String,
                                         duration candDuration: Double?, track: Track) -> Bool {
        // Duration gate — LRCLIB lengths are per-recording accurate; a big gap means
        // a different song. Enforced only when both lengths are known.
        if track.duration > 0, let d = candDuration, abs(d - track.duration) > 8 { return false }

        // What we actually know about the track: words from its title AND artist tag.
        let known = tokens(track.displayTitle).union(tokens(track.artist))
        let candTitleTokens = tokens(candTitle)
        guard !known.isEmpty, !candTitleTokens.isEmpty else { return false }

        // Most of the candidate's title words must be words we have.
        let containment = Double(candTitleTokens.intersection(known).count) / Double(candTitleTokens.count)
        if containment < 0.67 { return false }

        // The candidate's artist should also appear (softer: a YouTube "artist" is the
        // channel, but the real one is usually in the title) — unless the title is a
        // near-perfect match.
        let candArtistTokens = tokens(candArtist)
        return candArtistTokens.isEmpty
            || !candArtistTokens.isDisjoint(with: known)
            || containment >= 0.9
    }

    /// Normalize a string to a set of comparable word tokens: lowercased, diacritics
    /// folded, bracketed/`feat` noise removed, punctuation dropped, 1-char words out.
    private static func tokens(_ string: String) -> Set<String> {
        var text = string.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        text = text.replacing(bracketRegex, with: " ").replacing(featRegex, with: " ")
        let cleaned = String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return Set(cleaned.split(separator: " ").map(String.init).filter { $0.count >= 2 })
    }

    /// Split a "Artist - Title" style name into its two halves (title de-noised).
    /// nil when there's no " - " separator to split on.
    private static func parseArtistTitle(from name: String) -> (artist: String, title: String)? {
        guard let range = name.range(of: " - ") else { return nil }
        let artist = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        var title = String(name[range.upperBound...])
        title = title.replacing(featRegex, with: "").replacing(bracketRegex, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return (artist, title)
    }

    /// Search queries in priority order: the noise-stripped title alone (already holds
    /// the real "Artist - Title"), then artist + title when the artist adds something.
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

    // Bracketed groups "(…)"/"[…]" and a trailing "feat…/ft…" clause — noise for matching.
    nonisolated(unsafe) private static let bracketRegex = /[\(\[][^\)\]]*[\)\]]/
    nonisolated(unsafe) private static let featRegex = /(?i)\s*\b(?:feat|ft)\b\.?.*/
    // Release-noise parentheticals dropped from a search query (kept: "(feat…)").
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
        let trackName: String?
        let artistName: String?
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
