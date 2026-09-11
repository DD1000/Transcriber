import Foundation

/// Output naming is independent of the language spoken in a recording.
enum NamingLanguage: String, CaseIterable, Identifiable, Sendable {
    case original = "original"
    case english = "en"
    case spanish = "es-419"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Automatic · no translation"
        case .english: "English"
        case .spanish: "Español · Latin America"
        case .chineseSimplified: "简体中文 · Mainland China"
        }
    }
    var guidance: String {
        switch self {
        case .original: "Keeps speech-based names in the original language; scene names use English."
        case .english: "Natural English titles. Your original transcript stays unchanged."
        case .spanish: "Natural Latin American Spanish, with accents and ordinary local wording."
        case .chineseSimplified: "Natural Simplified Chinese titles, using Mainland Chinese wording."
        }
    }
    var workerCode: String { self == .original ? "en" : rawValue }
}

enum NamingEvidence: String, Sendable {
    case speech
    case scenes
}
