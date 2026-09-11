import Foundation

enum TitleGenerator {
    /// Keep a generated phrase grammatical: do not strip Spanish articles or split Chinese.
    static func localizedFilename(from title: String, preservingExtension extensionName: String, fallback: String) -> String {
        var base = title.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[\\/:*?\"<>|\p{Cc}\p{Cf}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        let suffix = "." + extensionName.lowercased()
        if base.lowercased().hasSuffix(suffix) { base.removeLast(suffix.count) }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave room for the extension and duplicate-number suffix on byte-limited filesystems.
        while base.utf8.count > max(1, 180 - suffix.utf8.count) { base.removeLast() }
        guard !base.isEmpty else { return fallback + suffix }
        return base.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private static let fillerWords: Set<String> = [
        "a", "an", "and", "are", "at", "de", "del", "el", "en", "es", "este", "esto", "for", "hola", "i", "la", "las", "los", "me", "my", "of", "oh", "okay", "para", "que", "the", "this", "to", "uh", "um", "un", "una", "y", "yo",
    ]

    static func filename(from transcript: String, preservingExtension extensionName: String, fallback: String) -> String {
        let sentence = transcript
            .split(whereSeparator: { ".!?…\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.split(separator: " ").count >= 3 }) ?? transcript

        let words = sentence
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .prefix(8)

        let title = words.isEmpty ? fallback : words.joined(separator: "-")
        let safeTitle = title
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))

        // Unspaced Chinese speech can be one very long token. Apply the same byte
        // and path safety rules even when the user chooses no translation.
        return localizedFilename(from: safeTitle, preservingExtension: extensionName, fallback: fallback)
    }
}
