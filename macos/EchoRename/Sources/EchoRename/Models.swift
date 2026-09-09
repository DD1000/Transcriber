import Foundation

enum VideoJobState: Equatable {
    case ready
    case extractingAudio
    case transcribing
    case proposed
    case renamed
    case failed(String)

    var label: String {
        switch self {
        case .ready: "Ready"
        case .extractingAudio: "Extracting audio"
        case .transcribing: "Transcribing locally"
        case .proposed: "Name suggested"
        case .renamed: "Renamed"
        case .failed(let message): message
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "circle"
        case .extractingAudio: "waveform"
        case .transcribing: "text.badge.star"
        case .proposed: "checkmark.circle.fill"
        case .renamed: "arrow.triangle.2.circlepath.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct VideoJob: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    let originalName: String
    var proposedName: String
    var transcript: String = ""
    var isSelected = true
    var state: VideoJobState = .ready

    init(url: URL) {
        self.url = url
        self.originalName = url.lastPathComponent
        self.proposedName = url.lastPathComponent
    }
}

struct RenameStep: Codable, Equatable {
    let originalPath: String
    let renamedPath: String
}

struct RenameBatch: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let steps: [RenameStep]
}

enum RenameError: LocalizedError {
    case noVideos
    case duplicateName(String)
    case destinationExists(String)
    case originalMissing(String)
    case undoUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideos: "No videos are ready to rename."
        case .duplicateName(let name): "More than one video is set to use \(name)."
        case .destinationExists(let name): "A file named \(name) already exists in this folder."
        case .originalMissing(let name): "The original video is missing: \(name)."
        case .undoUnavailable: "There is no completed rename batch to undo."
        }
    }
}
