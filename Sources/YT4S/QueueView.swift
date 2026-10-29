import SwiftUI
import YT4SCore

/// The Queue: header summary with Retry all failed and Clear finished, then one row per video.
struct QueueView: View {
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
                    if summary.showsRetryAllFailed {
                        Button("Retry all failed") { queue.retryAllFailed() }
                            .controlSize(.small)
                    }
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
        case .downloadAgain: queue.downloadAgain(id)
        case .showInFinder(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

private struct QueueRowView: View {
    let row: QueueRow
    let perform: (QueueRow.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                details
                HStack(spacing: 6) {
                    ForEach(row.actions, id: \.title) { action in
                        Button(action.title) { perform(action) }
                            .controlSize(.small)
                    }
                }
            }
            // Full row width, below the buttons, so opening it never moves Retry.
            if let failureDetails = row.details {
                FailureDetailsView(text: failureDetails)
                    .padding(.top, -4)
                    .padding(.bottom, 9)
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

/// The raw yt-dlp output of a failed row, collapsed under "Details", with Copy.
private struct FailureDetailsView: View {
    let text: String

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(text.isEmpty ? "yt-dlp printed nothing." : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
        } label: {
            Text("Details").font(.caption)
        }
    }
}

private extension QueueRow.Action {
    var title: String {
        switch self {
        case .cancel: "Cancel"
        case .retry: "Retry"
        case .remove: "Remove"
        case .downloadAgain: "Download again"
        case .showInFinder: "Show in Finder"
        }
    }
}
