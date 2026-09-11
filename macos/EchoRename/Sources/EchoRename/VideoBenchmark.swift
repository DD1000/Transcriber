import AVFoundation
import Foundation

/// One isolated model evaluation. The Python runner owns timeouts and run reports.
/// This path uses the production services, but never calls the rename executor.
enum VideoBenchmark {
    struct Result: Codable {
        let schemaVersion: Int
        let engine: String
        let modelID: String
        let startedAt: Date
        var elapsedSeconds: Double = 0
        var videoDurationSeconds: Double?
        var status = "failed"
        var transcript: String?
        var usefulSpeech: Bool?
        var sceneTitle: String?
        var sceneDescription: String?
        var suggestedFilename: String?
        var error: String?
    }

    static func run(arguments: [String]) async -> Int32 {
        guard arguments.count == 3, ["speech", "vision"].contains(arguments[0]) else {
            print("Usage: ClipName --benchmark speech|vision /absolute/video.mp4 /absolute/result.json")
            return 2
        }
        let engine = arguments[0]
        let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let temporaryDirectory = ProcessInfo.processInfo.environment["CLIPNAME_BENCHMARK_TEMP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard input.path != output.path,
              output.pathExtension == "json",
              !FileManager.default.fileExists(atPath: output.path) else {
            print("Benchmark output must be a new JSON file, separate from the video.")
            return 2
        }
        var result = Result(
            schemaVersion: 1,
            engine: engine,
            modelID: engine == "speech" ? LocalVideoTranscriber.highAccuracyModel : "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            startedAt: Date()
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            if let duration = try? await AVURLAsset(url: input).load(.duration).seconds,
               duration.isFinite { result.videoDurationSeconds = duration }
            if engine == "speech" {
                let transcriber = LocalVideoTranscriber(temporaryDirectory: temporaryDirectory)
                do {
                    let transcript = try await transcriber.transcribe(videoAt: input)
                    result.transcript = transcript
                    result.usefulSpeech = SpeechNamingPolicy.hasUsefulSpeech(transcript)
                    if result.usefulSpeech == true {
                        result.suggestedFilename = TitleGenerator.filename(
                            from: transcript,
                            preservingExtension: input.pathExtension,
                            fallback: input.deletingPathExtension().lastPathComponent
                        )
                    }
                    result.status = "completed"
                } catch AudioExtractionError.noAudioTrack {
                    result.status = "no_audio"
                    result.usefulSpeech = false
                } catch {
                    await transcriber.unload()
                    throw error
                }
                await transcriber.unload()
            } else {
                let scene = try await LocalSceneNamer(temporaryDirectory: temporaryDirectory).describe(videoAt: input)
                result.sceneTitle = scene.title
                result.sceneDescription = scene.description
                result.suggestedFilename = TitleGenerator.filename(
                    from: scene.title,
                    preservingExtension: input.pathExtension,
                    fallback: input.deletingPathExtension().lastPathComponent
                )
                result.status = "completed"
            }
        } catch {
            result.error = error.localizedDescription
        }
        let elapsed = start.duration(to: clock.now).components
        result.elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // The runner chooses a fresh output directory; never overwrite existing data.
            try encoder.encode(result).write(to: output, options: .withoutOverwriting)
        } catch {
            print("Could not save benchmark result: \(error.localizedDescription)")
            return 2
        }
        print("\(engine): \(result.status)")
        return result.status == "failed" ? 1 : 0
    }
}
