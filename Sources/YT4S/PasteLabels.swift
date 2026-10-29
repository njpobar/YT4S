import SwiftUI
import YT4SCore

/// Live Source detection under the paste box (prototype: "Detected: Playlist").
///
/// One line: a single "Detected: ..." caption. Several lines: "List of N links", then each
/// line's label next to its link. Lines that are not YouTube links are red; Download skips them.
struct PasteLabels: View {
    let paste: Paste
    let listingMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if paste.lines.count == 1, let line = paste.lines.first {
                label(line.isValid ? "Detected: \(line.label)" : line.label, valid: line.isValid)
            } else if paste.lines.count > 1 {
                if let summary = paste.summary {
                    label("Detected: \(summary)", valid: true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(paste.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 6) {
                                label(line.label, valid: line.isValid)
                                    .fixedSize()
                                Text(line.text)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 76)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let listingMessage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(listingMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, paste.lines.isEmpty && listingMessage == nil ? 0 : 6)
    }

    private func label(_ text: String, valid: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(valid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
    }
}
