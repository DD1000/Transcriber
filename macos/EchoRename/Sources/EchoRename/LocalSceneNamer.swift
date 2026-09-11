import Foundation
import Darwin

struct SceneDescription: Decodable, Sendable {
    let title: String
    let description: String
}

enum SceneNamingError: LocalizedError {
    case setupRequired
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .setupRequired: "Localized names and scene analysis need the local language model. Run ClipName’s setup-vision script, then try again."
        case .failed(let message): message
        case .timedOut: "Local naming took too long. Try again with fewer apps open."
        }
    }
}

actor LocalSceneNamer {
    private let temporaryDirectory: URL?

    init(temporaryDirectory: URL? = nil) {
        self.temporaryDirectory = temporaryDirectory
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipName/Vision", isDirectory: true)
    }

    private func runtime() throws -> (python: URL, model: URL, worker: URL) {
        let python = Self.supportDirectory.appendingPathComponent("runtime/bin/python")
        let model = Self.supportDirectory.appendingPathComponent("model")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path),
              let worker = Self.workerURL else {
            throw SceneNamingError.setupRequired
        }
        return (python, model, worker)
    }

    func describe(videoAt videoURL: URL, language: NamingLanguage = .original) async throws -> SceneDescription {
        let runtime = try runtime()
        let frames = try await VideoFrameSampler.sample(videoAt: videoURL, temporaryDirectory: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: frames.directory) }
        let data = try await run(python: runtime.python, worker: runtime.worker, model: runtime.model,
                                 directory: frames.directory, arguments: ["--language", language.workerCode, "--images"] + frames.images.map(\.path))
        guard let result = try? JSONDecoder().decode(SceneDescription.self, from: data), !result.title.isEmpty else {
            throw SceneNamingError.failed("No clear scene description was found. The original filename has been kept.")
        }
        return result
    }

    func localizedTitle(from text: String, evidence: NamingEvidence, language: NamingLanguage) async throws -> String {
        let runtime = try runtime()
        let directory = (temporaryDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("clipname-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.txt")
        // The original transcript remains in the view model; this private copy is always removed.
        try text.write(to: input, atomically: true, encoding: .utf8)
        let data = try await run(python: runtime.python, worker: runtime.worker, model: runtime.model,
                                 directory: directory, arguments: ["--text-file", input.path, "--source-kind", evidence.rawValue,
                                                                   "--language", language.workerCode])
        struct Title: Decodable { let title: String }
        guard let result = try? JSONDecoder().decode(Title.self, from: data), !result.title.isEmpty else {
            throw SceneNamingError.failed("A clear localized name could not be generated. The previous name has been kept.")
        }
        return result.title
    }

    private static var workerURL: URL? {
        // Packaged apps must not depend on a developer's .build directory.
        if let installed = Bundle.main.url(forResource: "scene_namer", withExtension: "py") {
            return installed
        }
        return Bundle.module.url(forResource: "scene_namer", withExtension: "py", subdirectory: "Resources")
    }

    private func run(python: URL, worker: URL, model: URL, directory: URL, arguments: [String]) async throws -> Data {
        let output = directory.appendingPathComponent("result.json")
        let log = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = python
        process.arguments = [worker.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
                             "--model", model.path, "--output", output.path] + arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(240)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() > deadline { throw SceneNamingError.timedOut }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                // Always reap the child before removing its input frames.
                await Task.detached {
                    let stopDeadline = Date().addingTimeInterval(3)
                    while process.isRunning && Date() < stopDeadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }.value
            }
            throw error
        }
        try Task.checkCancellation()
        guard let data = try? Data(contentsOf: output) else {
            throw SceneNamingError.failed("Local naming could not finish. The local model may need to be reinstalled.")
        }
        if let failure = try? JSONDecoder().decode(WorkerFailure.self, from: data) {
            throw SceneNamingError.failed(failure.error)
        }
        guard process.terminationStatus == 0 else {
            throw SceneNamingError.failed("Local naming could not finish. The previous filename has been kept.")
        }
        return data
    }

    private struct WorkerFailure: Decodable { let error: String }
}
