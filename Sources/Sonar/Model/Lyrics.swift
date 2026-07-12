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
        if let local = cached(for: track) { return local }
        return await fetchRemote(for: track)
    }

    /// Synchronous cache-only lookup — a fast local `.lrc` read, no network. Lets a
    /// caller show cached lyrics instantly (no loading spinner) and reserve the async
    /// network path for an actual cache miss.
    static func cached(for track: Track) -> [LyricLine]? {
        loadCache(for: track.url)
    }

    /// Network lookup (LRCLIB) for a cache miss; caches the result on a hit.
    static func fetchRemote(for track: Track) async -> [LyricLine]? {
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
        guard let lk = lookup(for: track) else { return nil }

        // 1. Exact /api/get on each candidate (artist, title) — precise and cheap when
        //    the tags (or a clean "Artist - Title" display name) are accurate.
        for artist in lk.artists {
            if let hit = await lrclibGetExact(artist: artist, title: lk.title,
                                              duration: track.duration) {
                return hit
            }
        }
        // 2. Fuzzy search fallback for messy names, but only ACCEPT a result that
        //    verifiably matches this track. Better no lyrics than someone else's.
        return await lrclibSearch(lk, track: track)
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

    /// Fuzzy fallback, keeping only results that pass a confidence gate (duration
    /// within a few seconds AND the title/artist words actually match). Tries the
    /// queries in priority order and, on the first that yields survivors, returns the
    /// one whose duration is closest. If nothing qualifies → nil.
    ///
    /// Query order matters for both recall and precision:
    ///   1. Structured `track_name` + `artist_name` — LRCLIB's fuzzy field search, the
    ///      highest-recall option for collab names however they're joined server-side.
    ///   2. Free-text `q=` with a separator-normalized artist + title — a broader net.
    ///   3. Title alone, but only when we have no artist at all (the gate guards it).
    private static func lrclibSearch(_ lk: Lookup, track: Track) async -> (raw: String, parsed: [LyricLine])? {
        var queries: [SearchQuery] = []
        for artist in lk.artists {
            queries.append(SearchQuery(track: lk.title, artist: normalizeArtist(artist)))
        }
        for artist in lk.artists {
            let q = (normalizeArtist(artist) + " " + lk.title).trimmingCharacters(in: .whitespaces)
            queries.append(SearchQuery(q: q))
        }
        if lk.artists.isEmpty { queries.append(SearchQuery(q: lk.title)) }

        var seen = Set<SearchQuery>()
        for query in queries where seen.insert(query).inserted {
            guard let results = await runSearch(query) else { continue }
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

    /// One `/api/search` request. Either free-text (`q`) or structured (`track_name`
    /// + optional `artist_name`); blank artist fields are dropped so LRCLIB doesn't
    /// over-constrain.
    private static func runSearch(_ query: SearchQuery) async -> [LRCLIBRecord]? {
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        var items: [URLQueryItem] = []
        if let q = query.q, !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let track = query.track, !track.isEmpty { items.append(URLQueryItem(name: "track_name", value: track)) }
        if let artist = query.artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard !items.isEmpty else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        return await get(url)
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

    // MARK: Query building

    /// One `/api/search` request's parameters — free-text (`q`) or structured
    /// (`track` + `artist`). Hashable so duplicate queries are only issued once.
    private struct SearchQuery: Hashable {
        var track: String?
        var artist: String?
        var q: String?
    }

    /// Normalized lookup terms for a track: a cleaned title plus candidate artist
    /// strings, best guess first — the file's own artist tag, then any "Artist - Title"
    /// prefix packed into the display name (YouTube style). nil when there's no title
    /// to search on.
    private struct Lookup {
        let title: String
        let artists: [String]
    }

    private static func lookup(for track: Track) -> Lookup? {
        let raw = track.displayTitle.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let dash = raw.range(of: " - ")
        let title = clean(dash.map { String(raw[$0.upperBound...]) } ?? raw)
        guard !title.isEmpty else { return nil }

        var artists: [String] = []
        for candidate in [track.artist, dash.map { String(raw[..<$0.lowerBound]) } ?? ""] {
            let a = candidate.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !artists.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                artists.append(a)
            }
        }
        return Lookup(title: title, artists: artists)
    }

    /// Strip bracketed groups and any trailing feat/ft clause, then collapse whitespace.
    /// Used for the canonical title — LRCLIB indexes the bare song name, so label tags
    /// like "[Ultra Records]" and "(Official Video)" only hurt recall.
    private static func clean(_ s: String) -> String {
        s.replacing(bracketRegex, with: " ")
            .replacing(featRegex, with: " ")
            .replacing(wsRegex, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Flatten collaboration separators (x, ×, &, vs, feat, and, /, ",", +, ;) to
    /// spaces so a query matches however LRCLIB happens to join the collaborators —
    /// "A x B", "A & B", "A, B" and "A/B" all become "A B".
    private static func normalizeArtist(_ s: String) -> String {
        clean(s).replacing(artistSepRegex, with: " ")
            .replacing(wsRegex, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // Bracketed groups "(…)"/"[…]" and a trailing "feat…/ft…" clause — noise for matching.
    nonisolated(unsafe) private static let bracketRegex = /[\(\[][^\)\]]*[\)\]]/
    nonisolated(unsafe) private static let featRegex = /(?i)\s*\b(?:feat|ft)\b\.?.*/
    nonisolated(unsafe) private static let wsRegex = /\s+/
    // A collaboration separator between two artists: a spaced word joiner (x/vs/and) or
    // a punctuation joiner (× & , ; / +). Normalized to a single space for search.
    nonisolated(unsafe) private static let artistSepRegex = /(?i)(?:\s+(?:x|vs|and)\b\.?|[×&,;\/+])\s*/

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
