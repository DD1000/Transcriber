import Foundation

enum TitleGenerator {
    private static let fillerWords: Set<String> = [
        "a", "an", "and", "are", "at", "de", "del", "el", "en", "es", "este", "esto", "for", "hola", "i", "la", "las", "los", "me", "my", "of", "oh", "okay", "que", "the", "this", "to", "uh", "um", "un", "una", "y", "yo",
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

        return "\(safeTitle.isEmpty ? fallback : safeTitle).\(extensionName.lowercased())"
    }
}
