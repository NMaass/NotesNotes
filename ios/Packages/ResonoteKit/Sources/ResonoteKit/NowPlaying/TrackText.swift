import Foundation

/// Text normalization shared by every now-playing source, so "Lithium - Remastered 2011"
/// from one service and "Lithium" from another are recognized as the same song.
public enum TrackText {
    /// Version markers that do not change which song it is. Live, acoustic, demo, and
    /// remix stay: those are different recordings someone may want to write about.
    private static let noiseMarkers = [
        "remaster", "remastered", "deluxe", "anniversary", "edition", "explicit", "clean",
        "mono", "stereo", "single version", "album version", "radio edit", "bonus track",
    ]

    private static let posix = Locale(identifier: "en_US_POSIX")
    /// "(…)" or "[…]", capturing what is inside; compiled once.
    private static let bracketed = try? NSRegularExpression(pattern: #"\s*[\(\[]([^\)\]]*)[\)\]]"#)

    /// Lowercased, diacritic-free, punctuation-collapsed text for comparisons.
    public static func fold(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: posix)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let collapsed = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(collapsed).split(separator: " ").joined(separator: " ")
    }

    /// The title without featured-artist credits and remaster/edition noise.
    public static func cleanTitle(_ title: String) -> String {
        var result = title
        // "Song (feat. X)", "Song [with X]", "Song - feat. X"
        result = result.replacingOccurrences(of: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s+-\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        // "Song (2011 Remaster)", "Song [Deluxe Edition]"
        if let bracketed { result = result.removingMatches(of: bracketed, where: isNoise) }
        // "Song - Remastered 2011", "Song - Single Version"
        if let dash = result.range(of: " - ", options: .backwards) {
            let tail = String(result[dash.upperBound...])
            if isNoise(tail) { result = String(result[..<dash.lowerBound]) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The primary artist: "A, B & C" and "A feat. B" both become "A".
    public static func primaryArtist(_ artist: String) -> String {
        let separators = [#"\s+(feat\.?|ft\.?|featuring|with|x|vs\.?)\s+"#, #"\s*[,;/]\s*"#, #"\s+&\s+"#]
        var result = artist
        for pattern in separators {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key two sources must share to count as the same song.
    public static func matchKey(artist: String, title: String) -> String {
        "\(fold(primaryArtist(artist)))|\(fold(cleanTitle(title)))"
    }

    private static func isNoise(_ fragment: String) -> Bool {
        let folded = fold(fragment)
        guard !folded.isEmpty else { return false }
        return noiseMarkers.contains { folded.contains($0) }
    }
}

private extension String {
    /// Removes matches of `regex` only where `predicate` accepts the first capture group.
    func removingMatches(of regex: NSRegularExpression, where predicate: (String) -> Bool) -> String {
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, range: nsRange).reversed() {
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: self),
                  let fullRange = Range(match.range, in: result),
                  predicate(String(self[groupRange])) else { continue }
            result.replaceSubrange(fullRange, with: "")
        }
        return result
    }
}
