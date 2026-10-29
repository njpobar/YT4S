import Foundation
import Observation

/// State and actions behind the main window: the paste box, the Download button, and the Queue.
@MainActor @Observable
public final class MainWindowModel {
    /// Paste box contents, one link per line. Not persisted.
    public var pasteText = ""
    /// Where downloads go. Saved across launches; changed with "Change..." (`chooseDownloadFolder`).
    public var downloadFolder: URL {
        didSet { settings?.downloadFolder = downloadFolder }
    }
    /// The choices new Queue items are downloaded with. Saved across launches.
    public var options: DownloadOptions {
        didSet { settings?.options = options }
    }
    /// A plain sentence shown near the Download button, or `nil`.
    public private(set) var errorMessage: String?

    public let queue: Queue
    /// Where choices are saved; `nil` for a model that saves nothing.
    @ObservationIgnored private let settings: Settings?

    public nonisolated static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YT4S", isDirectory: true)
    }

    /// Starts from the saved choices (first-run defaults if none) and saves every change.
    public init(queue: Queue, settings: Settings) {
        self.queue = queue
        self.settings = settings
        self.downloadFolder = settings.downloadFolder
        self.options = settings.options
    }

    /// A model that saves nothing, starting from default options.
    public init(queue: Queue, downloadFolder: URL = MainWindowModel.defaultDownloadFolder) {
        self.queue = queue
        self.settings = nil
        self.downloadFolder = downloadFolder
        self.options = .default
    }

    /// The user picked another Download folder with "Change...".
    public func chooseDownloadFolder(_ folder: URL) {
        downloadFolder = folder
        errorMessage = nil
    }

    public var canDownload: Bool { !links.isEmpty }

    /// Queues one item per pasted line and clears the paste box.
    /// The Source detection ticket replaces the line split with real Source detection.
    public func download() {
        let links = links
        guard !links.isEmpty else { return }
        // The folder is created on first Download, never at launch, and recreated if it went
        // missing, but only inside an existing parent. Never falls back to another folder.
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: downloadFolder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
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
