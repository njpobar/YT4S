import SwiftUI
import YT4SCore

/// The one-column main window (prototype variant A, issue #9), top to bottom:
/// paste box, [Format / Naming pattern rows: later tickets], Download folder + Download button,
/// Queue, [update footer: later ticket].
struct MainWindow: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PasteBox(text: $model.pasteText)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("Save to")
                    Text(model.downloadFolder.abbreviatingWithTildeInPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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

    private var activeCount: Int {
        queue.items.filter {
            switch $0.state {
            case .pending, .running: true
            case .finished, .alreadyDownloaded, .failed, .cancelled: false
            }
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if queue.items.isEmpty {
                Text("Nothing here yet. Paste a link to start.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                Spacer(minLength: 0)
            } else {
                HStack {
                    Text("Queue").fontWeight(.semibold)
                    Spacer()
                    if activeCount > 0 {
                        Text("\(activeCount) active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.items) { item in
                            QueueRowView(row: QueueRow(item))
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct QueueRowView: View {
    let row: QueueRow

    var body: some View {
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
        }
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
