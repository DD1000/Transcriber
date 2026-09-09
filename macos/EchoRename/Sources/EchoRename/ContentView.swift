import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: VideoRenameViewModel
    @State private var showRenameConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            jobList
            Divider()
            footer
        }
        .alert("EchoRename", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Rename \(model.proposedCount) video\(model.proposedCount == 1 ? "" : "s")?",
            isPresented: $showRenameConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Rename videos", role: .destructive) { model.renameSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the selected filenames on your Mac. The last batch can be undone from this app.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("EchoRename")
                    .font(.title2.weight(.bold))
                Text("Private video transcription and filename suggestions")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Whisper Large v3 Turbo", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
        }
        .padding(24)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button("Choose video folder", systemImage: "folder") { model.chooseFolder() }
                .buttonStyle(.borderedProminent)
            if let folderURL = model.folderURL {
                Text(folderURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder selected")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            Toggle("Include subfolders", isOn: $model.includeSubfolders)
                .toggleStyle(.checkbox)
            Button("Scan videos") { model.scanFolder() }
                .disabled(model.folderURL == nil || model.isScanning || model.isAnalyzing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private var jobList: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView(
                "Choose a folder to begin",
                systemImage: "folder.badge.questionmark",
                description: Text("EchoRename scans your selected folder, transcribes video audio locally, and lets you approve the final names."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach($model.jobs) { $job in
                        VideoRow(job: $job)
                    }
                } header: {
                    HStack {
                        Text("\(model.jobs.count) videos found")
                        Spacer()
                        Text("Edit any proposed name before renaming")
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.isAnalyzing {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 12) {
                Image(systemName: model.isAnalyzing ? "waveform" : "checkmark.shield")
                    .foregroundStyle(model.isAnalyzing ? Color.accentColor : Color.green)
                Text(model.notice)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Undo last rename", systemImage: "arrow.uturn.backward") { model.undoLastRename() }
                    .disabled(model.isAnalyzing)
                Button("Analyze \(model.selectedCount) video\(model.selectedCount == 1 ? "" : "s")", systemImage: "sparkles") { model.analyzeSelected() }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedCount == 0 || model.isScanning || model.isAnalyzing)
                Button("Rename \(model.proposedCount)", systemImage: "text.cursor") { showRenameConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proposedCount == 0 || model.isAnalyzing)
            }
        }
        .padding(20)
    }
}

private struct VideoRow: View {
    @Binding var job: VideoJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(job.originalName)", isOn: $job.isSelected)
                .labelsHidden()
                .accessibilityLabel("Select \(job.originalName)")
            Image(systemName: job.state.symbolName)
                .foregroundStyle(symbolColor)
                .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 7) {
                Text(job.originalName)
                    .font(.headline)
                    .lineLimit(1)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                if !job.transcript.isEmpty {
                    DisclosureGroup("View transcript") {
                        Text(job.transcript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 5)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 12)
            TextField("Suggested filename", text: $job.proposedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .disabled(job.state != .proposed)
        }
        .padding(.vertical, 5)
    }

    private var symbolColor: Color {
        switch job.state {
        case .failed: .red
        case .proposed, .renamed: .green
        case .extractingAudio, .transcribing: .accentColor
        case .ready: .secondary
        }
    }

    private var isFailed: Bool {
        if case .failed = job.state { return true }
        return false
    }
}
