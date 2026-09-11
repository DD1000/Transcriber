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
        var normalized = withoutCaptions.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        // Remove stock Chinese signoffs before judging the remaining topic. A
        // useful sentence must not become noise just because it ends with thanks.
        let chineseBoilerplate = [
            "感谢大家的观看", "感謝大家的觀看", "谢谢大家的观看", "謝謝大家的觀看",
            "感谢大家观看", "感謝大家觀看", "谢谢大家观看", "謝謝大家觀看",
            "感谢观看", "感謝觀看", "谢谢观看", "謝謝觀看", "感谢收看", "感謝收看", "谢谢收看", "謝謝收看",
            "字幕制作", "字幕製作", "我们下期再见", "我們下期再見", "下期再见", "下期再見", "下次再见", "下次再見",
            "不要忘记", "不要忘記", "别忘了", "別忘了", "记得", "記得", "点赞", "點讚", "订阅", "訂閱",
            "嗯", "呃", "啊", "哦", "唔",
        ]
        for phrase in chineseBoilerplate {
            normalized = normalized.replacingOccurrences(of: phrase, with: " ")
        }
        let han = normalized.unicodeScalars.filter { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        if han.count >= 8, Set(han).count >= 5 { return true }
        // Leftover Chinese fragments are not separate meaningful English or
        // Spanish words merely because signoff removal inserted spaces.
        let withoutHan = normalized.replacingOccurrences(of: #"[\u3400-\u4DBF\u4E00-\u9FFF]+"#, with: " ", options: .regularExpression)
        let words = withoutHan.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let ignored: Set<String> = ["music", "musica", "applause", "silence", "inaudible", "instrumental", "um", "uh", "oh", "hmm"]
        let content = words.filter { !ignored.contains($0) }
        guard content.count >= 4, Set(content).count >= 3 else { return false }
        let phrase = content.joined(separator: " ")
        let boilerplate = ["thank you for watching", "thanks for watching", "gracias por ver", "gracias por mirar", "subtitles by", "subtitulos por", "amara org"]
        if boilerplate.contains(where: { phrase.contains($0) }) && content.count <= 16 { return false }
        return true
    }
}
