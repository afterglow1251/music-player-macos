import Foundation

/// Lightweight fuzzy matching for the library search — tolerant of typos, dropped
/// letters and abbreviations (in the spirit of Fuse.js / fzf), with no dependency.
///
/// `score` tries the cheapest, strongest signals first and only falls back to the
/// expensive edit-distance pass when there's no ordered match:
///   1. direct substring      → strongest (rewards an early position)
///   2. ordered subsequence    → abbreviations / dropped letters
///   3. Levenshtein tolerance  → actual typos (wrong / swapped letters)
enum FuzzySearch {
    /// Best score of the query against any of the given fields (title, artist…).
    /// Returns nil when nothing matches well enough.
    static func score(_ query: String, in fields: [String]) -> Double? {
        fields.compactMap { score(query, $0) }.max()
    }

    /// Score `query` against `text`: nil = no match, otherwise 0...1 (higher = better).
    static func score(_ query: String, _ text: String) -> Double? {
        let q = Array(fold(query))
        let t = Array(fold(text))
        guard !q.isEmpty else { return 1 }
        guard !t.isEmpty, q.count <= t.count + 2 else { return t.isEmpty ? nil : nil }

        if let start = firstIndexOfSubarray(q, in: t) {
            return 1.0 - 0.15 * (Double(start) / Double(t.count))     // ~0.85...1.0
        }
        if let sub = subsequenceScore(q, t) {
            return sub                                               // ~0.35...0.85
        }
        return typoScore(q, t)                                      // ~0...0.55
    }

    // MARK: Normalisation

    /// Lowercase + strip diacritics so "Beyoncé" matches "beyonce".
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Substring

    private static func firstIndexOfSubarray(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        for start in 0...(t.count - q.count) {
            var matched = true
            for i in 0..<q.count where t[start + i] != q[i] { matched = false; break }
            if matched { return start }
        }
        return nil
    }

    // MARK: Subsequence

    /// All query characters appear in `t` in order. Score rewards contiguous runs
    /// (fewer gaps) and an early first match. nil if not a subsequence.
    private static func subsequenceScore(_ q: [Character], _ t: [Character]) -> Double? {
        var ti = 0
        var firstIndex = -1
        var runs = 0
        var lastMatched = -2
        for qc in q {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    if firstIndex < 0 { firstIndex = ti }
                    if ti != lastMatched + 1 { runs += 1 }
                    lastMatched = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        let contiguity = 1.0 - Double(max(0, runs - 1)) / Double(q.count)
        let earliness = 1.0 - Double(firstIndex) / Double(t.count)
        return 0.35 + 0.5 * (0.7 * contiguity + 0.3 * earliness)
    }

    // MARK: Typo tolerance

    /// Smallest edit distance between the query and any similar-length window of the
    /// text, tolerating ~a third of the query length in errors.
    private static func typoScore(_ q: [Character], _ t: [Character]) -> Double? {
        let tolerance = max(1, Int((Double(q.count) * 0.34).rounded()))
        var best = tolerance + 1

        let lo = max(1, q.count - tolerance)
        let hi = min(t.count, q.count + tolerance)
        guard lo <= hi else { return nil }

        for len in lo...hi {
            var start = 0
            while start + len <= t.count {
                let d = levenshtein(q, Array(t[start..<start + len]), maxAllowed: tolerance)
                if d < best { best = d }
                if best == 0 { break }
                start += 1
            }
            if best == 0 { break }
        }
        guard best <= tolerance else { return nil }
        return 0.55 * (1.0 - Double(best) / Double(tolerance + 1))
    }

    /// Bounded Levenshtein: bails out early once the running minimum exceeds the
    /// allowance (returns `maxAllowed + 1`).
    private static func levenshtein(_ a: [Character], _ b: [Character], maxAllowed: Int) -> Int {
        if abs(a.count - b.count) > maxAllowed { return maxAllowed + 1 }
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > maxAllowed { return maxAllowed + 1 }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
