import Foundation
import Observation

/// State and actions behind the main window: the paste box, the Download button, and the Queue.
@MainActor @Observable
public final class MainWindowModel {
    /// Paste box contents, one link per line. Not persisted.
    public var pasteText = ""
    /// Where downloads go. The settings ticket persists and lets the user change it.
    public var downloadFolder: URL
    /// The choices new Queue items are downloaded with.
    public var options: DownloadOptions = .default
    /// A plain sentence shown near the Download button, or `nil`.
    public private(set) var errorMessage: String?

    public let queue: Queue

    public static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YT4S", isDirectory: true)
    }

    public init(queue: Queue, downloadFolder: URL = MainWindowModel.defaultDownloadFolder) {
        self.queue = queue
        self.downloadFolder = downloadFolder
    }

    public var canDownload: Bool { !links.isEmpty }

    /// Queues one item per pasted line and clears the paste box.
    /// The Source detection ticket replaces the line split with real Source detection.
    public func download() {
        let links = links
        guard !links.isEmpty else { return }
        // The folder is created on first Download, never at launch.
        if !FileManager.default.fileExists(atPath: downloadFolder.path) {
            do {
                try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: false)
            } catch {
                errorMessage = "Couldn't create the folder \(downloadFolder.path). Choose another Download folder."
                return
            }
        }
        errorMessage = nil
        for link in links {
            queue.add(DownloadRequest(url: link, downloadFolder: downloadFolder, options: options))
        }
        pasteText = ""
    }

    private var links: [String] {
        pasteText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
