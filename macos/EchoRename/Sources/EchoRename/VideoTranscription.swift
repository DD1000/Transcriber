@preconcurrency import AVFoundation
import Foundation
// WhisperKit is compiled in Swift 5 mode, without Swift 6 concurrency annotations.
// Its private instance is used only by the view model's single analysis task,
// which awaits transcription and unloading sequentially (actors are reentrant).
@preconcurrency import WhisperKit

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case couldNotCreateExporter
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This video does not have an audio track."
        case .couldNotCreateExporter: "macOS could not prepare this video’s audio."
        case .exportFailed(let message): "Audio extraction failed: \(message)"
        }
    }
}

enum AudioExtractor {
    static func extractAudio(from videoURL: URL, temporaryDirectory: URL? = nil) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioExtractionError.noAudioTrack }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractionError.couldNotCreateExporter
        }

        let outputURL = (temporaryDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("echorename-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: AudioExtractionError.exportFailed(exporter.error?.localizedDescription ?? "Unknown error"))
                default:
                    continuation.resume(throwing: AudioExtractionError.exportFailed("The export did not finish."))
                }
            }
        }
        return outputURL
    }
}

actor LocalVideoTranscriber {
    static let highAccuracyModel = "large-v3-v20240930_626MB"
    private var whisperKit: WhisperKit?
    private let temporaryDirectory: URL?

    init(temporaryDirectory: URL? = nil) {
        self.temporaryDirectory = temporaryDirectory
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    func transcribe(videoAt videoURL: URL) async throws -> String {
        let audioURL = try await AudioExtractor.extractAudio(from: videoURL, temporaryDirectory: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        if whisperKit == nil {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: Self.highAccuracyModel))
        }
        guard let whisperKit else { return "" }

        let options = AudioInputOptions(audioLoadingMode: .incremental)
        let results = try await whisperKit.transcribe(audioPath: audioURL.path, audioInputOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
