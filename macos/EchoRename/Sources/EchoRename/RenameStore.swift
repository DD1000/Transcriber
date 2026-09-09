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

        let destinations = selected.map { $0.url.deletingLastPathComponent().appendingPathComponent($0.proposedName) }
        let lowercasedNames = destinations.map { $0.path.lowercased() }
        guard Set(lowercasedNames).count == lowercasedNames.count else {
            throw RenameError.duplicateName("the same target filename")
        }

        let originals = Set(selected.map(\.url.path))
        for destination in destinations where FileManager.default.fileExists(atPath: destination.path) && !originals.contains(destination.path) {
            throw RenameError.destinationExists(destination.lastPathComponent)
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
            steps: zip(selected, destinations).map { RenameStep(originalPath: $0.0.url.path, renamedPath: $0.1.path) },
        )
        try RenameHistoryStore.append(batch)
        return batch
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
