import SwiftUI
import YT4SCore

/// The one-column main window (prototype variant A, issue #9), top to bottom:
/// paste box, Format row, [Naming pattern row: later ticket], Download folder + Download button,
/// Queue, [update footer: later ticket].
struct MainWindow: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PasteBox(text: $model.pasteText)
            PasteLabels(paste: model.paste, listingMessage: model.listingMessage)

            FormatRow(options: $model.options)
                .padding(.top, 12)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("Save to")
                    HStack(spacing: 8) {
                        Text(model.downloadFolder.abbreviatingWithTildeInPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(model.downloadFolder.path)
                        Button("Change...") { chooseDownloadFolder() }
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 16)
                Button("Download") { model.download() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canDownload)
            }
            .padding(.top, 14)

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.top, 16)
                .padding(.bottom, 8)

            QueueView(queue: model.queue)
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 640)
    }
}

extension MainWindow {
    /// Folder picker for "Change...". Opens at the current folder, or its parent if it is gone.
    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where YT4S saves downloads."
        let current = model.downloadFolder
        panel.directoryURL = FileManager.default.fileExists(atPath: current.path)
            ? current : current.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.chooseDownloadFolder(url)
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }
}

/// "Get": Format (Video / MP3) and, for Video, the Quality preset.
private struct FormatRow: View {
    @Binding var options: DownloadOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("Get")
            HStack(spacing: 10) {
                Picker("Format", selection: $options.format) {
                    ForEach(Format.allCases, id: \.self) { Text($0.label) }
                }
                .fixedSize()
                if options.format.usesQualityPreset {
                    Picker("Quality", selection: $options.quality) {
                        ForEach(QualityPreset.allCases, id: \.self) { Text($0.label) }
                    }
                    .fixedSize()
                } else {
                    Text("High quality, with cover art")
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// Multi-line paste box, one link per line.
private struct PasteBox: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(height: 72)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste a video, playlist or channel link (several links: one per line)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct QueueView: View {
    let queue: Queue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if queue.items.isEmpty {
                Text("Nothing here yet. Paste a link to start.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                Spacer(minLength: 0)
            } else {
                let summary = QueueSummary(queue.items)
                HStack(spacing: 10) {
                    Text("Queue").fontWeight(.semibold)
                    Text(summary.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Clear finished") { queue.clearFinished() }
                        .controlSize(.small)
                        .disabled(!summary.hasFinished)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.items) { item in
                            QueueRowView(row: QueueRow(item)) { action in
                                perform(action, on: item.id)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func perform(_ action: QueueRow.Action, on id: QueueItem.ID) {
        switch action {
        case .cancel: queue.cancel(id)
        case .retry: queue.retry(id)
        case .remove: queue.remove(id)
        case .showInFinder(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

private struct QueueRowView: View {
    let row: QueueRow
    let perform: (QueueRow.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            details
            HStack(spacing: 6) {
                ForEach(row.actions, id: \.title) { action in
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            if row.showsProgress {
                if let fraction = row.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(row.status)
                .font(.caption)
                .foregroundStyle(statusColor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        switch row.tone {
        case .normal: .secondary
        case .success: .green
        case .failure: .red
        case .skipped: .orange
        }
    }
}

private extension QueueRow.Action {
    var title: String {
        switch self {
        case .cancel: "Cancel"
        case .retry: "Retry"
        case .remove: "Remove"
        case .showInFinder: "Show in Finder"
        }
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
