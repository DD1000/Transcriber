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

    private let transcriber = LocalVideoTranscriber()
    private let supportedExtensions: Set<String> = ["avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm"]

    var selectedCount: Int { jobs.filter(\.isSelected).count }
    var proposedCount: Int { jobs.filter { $0.isSelected && $0.state == .proposed && $0.proposedName != $0.url.lastPathComponent }.count }
    var progress: Double { jobs.isEmpty ? 0 : Double(completedJobs) / Double(jobs.filter(\.isSelected).count) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video folder"
        panel.message = "EchoRename will only work with videos inside this folder."
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
        let selectedIDs = jobs.filter(\.isSelected).map(\.id)
        guard !selectedIDs.isEmpty else { return }
        isAnalyzing = true
        completedJobs = 0
        errorMessage = nil
        notice = "Loading the high-accuracy local transcription model…"

        Task {
            for jobID in selectedIDs {
                guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                jobs[index].state = .extractingAudio
                notice = "Extracting audio from \(jobs[index].originalName)…"
                do {
                    jobs[index].state = .transcribing
                    notice = "Transcribing \(jobs[index].originalName) locally…"
                    let transcript = try await transcriber.transcribe(videoAt: jobs[index].url)
                    jobs[index].transcript = transcript
                    let extensionName = jobs[index].url.pathExtension
                    let fallback = jobs[index].url.deletingPathExtension().lastPathComponent
                    jobs[index].proposedName = TitleGenerator.filename(from: transcript, preservingExtension: extensionName, fallback: fallback)
                    jobs[index].state = .proposed
                } catch {
                    jobs[index].state = .failed(error.localizedDescription)
                }
                completedJobs += 1
            }
            isAnalyzing = false
            notice = "Review the proposed names, edit any you want, then rename the selected videos."
        }
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
