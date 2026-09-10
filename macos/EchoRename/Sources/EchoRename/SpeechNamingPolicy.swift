import Foundation

enum NamingMode: String, CaseIterable, Identifiable {
    case automatic = "Speech + scenes"
    case scenesOnly = "Scenes only"
    var id: String { rawValue }
}

enum SpeechNamingPolicy {
    // Whisper can emit these captions or stock phrases over silence/music.
    static func hasUsefulSpeech(_ transcript: String) -> Bool {
        let withoutCaptions = transcript.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)|[♪♫]+"#, with: " ", options: .regularExpression
        )
        let normalized = withoutCaptions.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let ignored: Set<String> = ["music", "musica", "applause", "silence", "inaudible", "instrumental", "um", "uh", "oh", "hmm"]
        let content = words.filter { !ignored.contains($0) }
        guard content.count >= 4, Set(content).count >= 3 else { return false }
        let phrase = content.joined(separator: " ")
        let boilerplate = ["thank you for watching", "thanks for watching", "gracias por ver", "gracias por mirar", "subtitles by", "subtitulos por", "amara org"]
        if boilerplate.contains(where: { phrase.contains($0) }) && content.count <= 16 { return false }
        return true
    }
}
