import Foundation

enum RenameHistoryStore {
    private static let fileName = "rename-history.json"

    private static var historyURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoRename", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    static func latest() -> RenameBatch? {
        guard let data = try? Data(contentsOf: historyURL) else { return nil }
        return try? JSONDecoder().decode([RenameBatch].self, from: data).last
    }

    static func append(_ batch: RenameBatch) throws {
        var entries: [RenameBatch] = []
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([RenameBatch].self, from: data) {
            entries = saved
        }
        entries.append(batch)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: historyURL, options: .atomic)
    }

    static func removeLatest() throws {
        guard let data = try? Data(contentsOf: historyURL), var entries = try? JSONDecoder().decode([RenameBatch].self, from: data), !entries.isEmpty else {
            throw RenameError.undoUnavailable
        }
        entries.removeLast()
        let updated = try JSONEncoder().encode(entries)
        try updated.write(to: historyURL, options: .atomic)
    }
}

enum RenameExecutor {
    static func rename(_ jobs: [VideoJob]) throws -> RenameBatch {
        let selected = jobs.filter { $0.isSelected && $0.state == .proposed && $0.proposedName != $0.url.lastPathComponent }
        guard !selected.isEmpty else { throw RenameError.noVideos }

        let originals = Set(selected.map(\.url.path))
        var reservedPaths = Set<String>()
        let destinations = selected.map { job -> URL in
            let directory = job.url.deletingLastPathComponent()
            let preferredName = normalizedFilename(job.proposedName, fallbackExtension: job.url.pathExtension)
            var candidate = directory.appendingPathComponent(preferredName)
            var suffix = 2

            while reservedPaths.contains(candidate.path.lowercased()) ||
                    (FileManager.default.fileExists(atPath: candidate.path) && !originals.contains(candidate.path)) {
                candidate = directory.appendingPathComponent(numberedFilename(preferredName, suffix: suffix, fallbackExtension: job.url.pathExtension))
                suffix += 1
            }
            reservedPaths.insert(candidate.path.lowercased())
            return candidate
        }

        let temporaryURLs = selected.map {
            $0.url.deletingLastPathComponent().appendingPathComponent(".echorename-\(UUID().uuidString).tmp")
        }
        for (job, temporaryURL) in zip(selected, temporaryURLs) {
            try FileManager.default.moveItem(at: job.url, to: temporaryURL)
        }
        for (temporaryURL, destination) in zip(temporaryURLs, destinations) {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }

        let batch = RenameBatch(
            id: UUID(),
            createdAt: .now,
            steps: zip(selected, destinations).map { RenameStep(originalPath: $0.0.url.path, renamedPath: $0.1.path) }
        )
        try RenameHistoryStore.append(batch)
        return batch
    }

    private static func normalizedFilename(_ name: String, fallbackExtension: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmed.isEmpty ? "untitled" : trimmed)
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
        return "\(base.isEmpty ? "untitled" : base).\(fileExtension)"
    }

    private static func numberedFilename(_ filename: String, suffix: Int, fallbackExtension: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let base = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
        return "\(base) \(suffix).\(fileExtension)"
    }

    static func undo(_ batch: RenameBatch) throws {
        let fileManager = FileManager.default
        for step in batch.steps where !fileManager.fileExists(atPath: step.renamedPath) {
            throw RenameError.originalMissing(URL(fileURLWithPath: step.renamedPath).lastPathComponent)
        }
        for step in batch.steps where fileManager.fileExists(atPath: step.originalPath) {
            throw RenameError.destinationExists(URL(fileURLWithPath: step.originalPath).lastPathComponent)
        }

        let temporaryURLs = batch.steps.map {
            URL(fileURLWithPath: $0.renamedPath).deletingLastPathComponent().appendingPathComponent(".echorename-undo-\(UUID().uuidString).tmp")
        }
        for (step, temporaryURL) in zip(batch.steps, temporaryURLs) {
            try fileManager.moveItem(at: URL(fileURLWithPath: step.renamedPath), to: temporaryURL)
        }
        for (temporaryURL, step) in zip(temporaryURLs, batch.steps) {
            try fileManager.moveItem(at: temporaryURL, to: URL(fileURLWithPath: step.originalPath))
        }
        try RenameHistoryStore.removeLatest()
    }
}
