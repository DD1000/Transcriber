import AppKit
import Foundation

@MainActor
final class VideoRenameViewModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var includeSubfolders = true
    @Published var jobs: [VideoJob] = []
    @Published var isScanning = false
    @Published var isAnalyzing = false
    @Published var completedJobs = 0
    @Published var notice = "Choose a folder to begin. Videos and audio stay on your Mac."
    @Published var errorMessage: String?
    @Published var namingMode: NamingMode = .automatic
    @Published var namingLanguage = NamingLanguage(rawValue: UserDefaults.standard.string(forKey: "namingLanguage") ?? "original") ?? .original {
        didSet { UserDefaults.standard.set(namingLanguage.rawValue, forKey: "namingLanguage") }
    }
    @Published var analysisTotal = 0

    private let transcriber = LocalVideoTranscriber()
    private let sceneNamer = LocalSceneNamer()
    private var analysisTask: Task<Void, Never>?
    private let supportedExtensions: Set<String> = ["avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm"]

    var selectedCount: Int { jobs.filter(\.isSelected).count }
    var proposedCount: Int { jobs.filter { $0.isSelected && $0.state == .proposed && $0.proposedName != $0.url.lastPathComponent }.count }
    var reusableCount: Int { jobs.filter { $0.isSelected && $0.namingEvidence != nil }.count }
    var progress: Double { analysisTotal == 0 ? 0 : Double(completedJobs) / Double(analysisTotal) }

    func chooseFolder() {
        guard !isAnalyzing && !isScanning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a video folder"
        panel.message = "ClipName will only work with videos inside this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
            jobs = []
            notice = "Ready to scan \(url.lastPathComponent)."
        }
    }

    func scanFolder() {
        guard !isAnalyzing && !isScanning else { return }
        guard let folderURL else { return }
        isScanning = true
        errorMessage = nil
        notice = "Scanning videos…"

        Task {
            let extensions = supportedExtensions
            let recursive = includeSubfolders
            let found = await Task.detached(priority: .userInitiated) {
                Self.videoURLs(in: folderURL, recursive: recursive, supportedExtensions: extensions)
            }.value
            jobs = found.map(VideoJob.init(url:))
            isScanning = false
            notice = found.isEmpty ? "No supported videos were found." : "Found \(found.count) video\(found.count == 1 ? "" : "s"). Select the ones to analyze."
        }
    }

    func analyzeSelected() {
        guard !isAnalyzing && !isScanning else { return }
        let selectedIDs = jobs.filter(\.isSelected).map(\.id)
        guard !selectedIDs.isEmpty else { return }
        isAnalyzing = true
        completedJobs = 0
        analysisTotal = selectedIDs.count
        errorMessage = nil
        let mode = namingMode
        let language = namingLanguage
        notice = mode == .scenesOnly ? "Preparing scene analysis…" : "Preparing local transcription…"

        analysisTask = Task {
            var sceneIDs: [UUID] = []
            var namingIDs: [UUID] = []
            // Finish speech first, then free its models before starting vision.
            for jobID in selectedIDs {
                if Task.isCancelled { break }
                guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                jobs[index].transcript = ""
                jobs[index].visualDescription = ""
                jobs[index].namingSource = ""
                jobs[index].namingEvidence = nil
                jobs[index].suggestedLanguage = nil
                if mode == .scenesOnly {
                    jobs[index].state = .waitingForScenes
                    sceneIDs.append(jobID)
                    continue
                }
                do {
                    jobs[index].state = .transcribing
                    notice = "Transcribing \(jobs[index].originalName) locally…"
                    let transcript = try await transcriber.transcribe(videoAt: jobs[index].url)
                    try Task.checkCancellation()
                    jobs[index].transcript = transcript
                    guard SpeechNamingPolicy.hasUsefulSpeech(transcript) else {
                        jobs[index].state = .waitingForScenes
                        sceneIDs.append(jobID)
                        continue
                    }
                    jobs[index].namingEvidence = .speech
                    if language == .original {
                        suggest(transcript, at: index, evidence: .speech, language: language, legacy: true)
                    } else {
                        jobs[index].state = .waitingForNames
                        namingIDs.append(jobID)
                        continue
                    }
                } catch {
                    if Task.isCancelled { break }
                    // Videos without audio, or with unreadable audio, can still be named visually.
                    jobs[index].state = .waitingForScenes
                    sceneIDs.append(jobID)
                    continue
                }
                completedJobs += 1
            }
            await transcriber.unload()
            await updateSuggestions(for: namingIDs, language: language)
            for jobID in sceneIDs {
                if Task.isCancelled { break }
                guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                jobs[index].state = .analyzingScenes
                notice = "Looking at scenes in \(jobs[index].originalName)…"
                do {
                    let scene = try await sceneNamer.describe(videoAt: jobs[index].url, language: language)
                    try Task.checkCancellation()
                    jobs[index].visualDescription = scene.description
                    jobs[index].namingEvidence = .scenes
                    suggest(scene.title, at: index, evidence: .scenes, language: language, legacy: language == .original)
                } catch {
                    if Task.isCancelled { break }
                    jobs[index].state = .failed(error.localizedDescription)
                }
                completedJobs += 1
            }
            finishAnalysis(selectedIDs)
        }
    }

    /// Reuses the original analysis, never a previously translated title.
    func updateSelectedNames() {
        guard !isAnalyzing && !isScanning else { return }
        let ids = jobs.filter { $0.isSelected && $0.namingEvidence != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        let previousStates = Dictionary(uniqueKeysWithValues: jobs.filter { ids.contains($0.id) }.map { ($0.id, $0.state) })
        let language = namingLanguage
        isAnalyzing = true
        completedJobs = 0
        analysisTotal = ids.count
        errorMessage = nil
        notice = "Updating suggestions from saved analysis. Your files are unchanged."
        for index in jobs.indices where ids.contains(jobs[index].id) {
            jobs[index].state = .waitingForNames
        }
        analysisTask = Task {
            await updateSuggestions(for: ids, language: language)
            finishAnalysis(ids, restoring: previousStates)
        }
    }

    private func updateSuggestions(for ids: [UUID], language: NamingLanguage) async {
        for id in ids {
            if Task.isCancelled { break }
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  let evidence = jobs[index].namingEvidence else { continue }
            jobs[index].state = .naming
            notice = "Writing a name for \(jobs[index].originalName)…"
            do {
                let source = evidence == .speech ? jobs[index].transcript : jobs[index].visualDescription
                if language == .original && evidence == .speech {
                    suggest(source, at: index, evidence: evidence, language: language, legacy: true)
                } else {
                    let title = try await sceneNamer.localizedTitle(from: source, evidence: evidence, language: language)
                    try Task.checkCancellation()
                    suggest(title, at: index, evidence: evidence, language: language)
                }
            } catch {
                if Task.isCancelled { break }
                // Keep the previous name and original analysis available for a retry.
                jobs[index].state = .failed(error.localizedDescription)
            }
            completedJobs += 1
        }
    }

    private func suggest(_ title: String, at index: Int, evidence: NamingEvidence, language: NamingLanguage, legacy: Bool = false) {
        let extensionName = jobs[index].url.pathExtension
        let fallback = jobs[index].url.deletingPathExtension().lastPathComponent
        jobs[index].proposedName = legacy
            ? TitleGenerator.filename(from: title, preservingExtension: extensionName, fallback: fallback)
            : TitleGenerator.localizedFilename(from: title, preservingExtension: extensionName, fallback: fallback)
        jobs[index].namingSource = evidence == .speech ? "Based on speech" : "Based on video scenes"
        jobs[index].suggestedLanguage = language
        jobs[index].state = .proposed
    }

    private func finishAnalysis(_ ids: [UUID], restoring previousStates: [UUID: VideoJobState] = [:]) {
        for index in jobs.indices where ids.contains(jobs[index].id) {
            if [.waitingForScenes, .analyzingScenes, .transcribing, .extractingAudio, .waitingForNames, .naming].contains(jobs[index].state) {
                jobs[index].state = previousStates[jobs[index].id] ?? .ready
            }
        }
        isAnalyzing = false
        analysisTask = nil
        notice = Task.isCancelled
            ? "Stopped. Completed suggestions are ready to review. Your files are unchanged."
            : "Suggestions ready. Review names and any errors, then choose Rename to apply them."
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        notice = "Stopping the current operation…"
    }

    func renameSelected() {
        do {
            let batch = try RenameExecutor.rename(jobs)
            let byOriginalPath = Dictionary(uniqueKeysWithValues: batch.steps.map { ($0.originalPath, $0.renamedPath) })
            for index in jobs.indices {
                if let renamedPath = byOriginalPath[jobs[index].url.path] {
                    jobs[index].url = URL(fileURLWithPath: renamedPath)
                    jobs[index].proposedName = URL(fileURLWithPath: renamedPath).lastPathComponent
                    jobs[index].state = .renamed
                }
            }
            notice = "Renamed \(batch.steps.count) video\(batch.steps.count == 1 ? "" : "s"). You can undo this batch."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoLastRename() {
        do {
            guard let batch = RenameHistoryStore.latest() else { throw RenameError.undoUnavailable }
            try RenameExecutor.undo(batch)
            notice = "Restored \(batch.steps.count) original filename\(batch.steps.count == 1 ? "" : "s")."
            scanFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func videoURLs(in folderURL: URL, recursive: Bool, supportedExtensions: Set<String>) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: Array(keys), options: options) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return false }
            return true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
