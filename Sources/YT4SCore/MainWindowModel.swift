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

    /// The paste box read as Sources, with a live label per line.
    public var paste: Paste { Paste(pasteText) }

    public var canDownload: Bool { !paste.sources.isEmpty }

    /// Shown while Playlist and Channel sources are being listed, e.g. "Looking up the videos of 1 playlist...".
    public var listingMessage: String? {
        let playlists = listingSources.count { $0.kind == .playlist }
        let channels = listingSources.count { $0.kind == .channel }
        let parts = [(playlists, "playlist"), (channels, "channel")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : "Looking up the videos of \(parts.joined(separator: " and "))..."
    }

    /// Playlist and Channel sources still being listed, in paste order.
    private var listingSources: [Source] = []
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var listingGeneration = 0

    /// Queues one row per video of every pasted Source, in paste order, and clears the paste box
    /// except for lines that are not YouTube links (never sent to yt-dlp, left there to fix).
    /// Video links queue at once; Playlist and Channel sources are listed by yt-dlp first.
    public func download() {
        let paste = paste
        let sources = paste.sources
        guard !sources.isEmpty else { return }
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
        pasteText = paste.invalidText

        let folder = downloadFolder
        let options = options
        if listing == nil, sources.allSatisfy({ $0.kind == .video }) {
            for case .video(let id) in sources {
                queue.add(DownloadRequest(
                    url: Source.video(id: id).url, downloadFolder: folder, options: options,
                    origin: VideoOrigin(sourceKind: .video, videoID: id)
                ))
            }
            return
        }

        // Listing runs after any earlier batch still being listed, so rows keep paste order.
        let previous = listing
        listingSources += sources.filter { $0.kind != .video }
        listingGeneration += 1
        let generation = listingGeneration
        let expander = SourceExpander(runner: queue.runner)
        listing = Task { [weak self] in
            await previous?.value
            for source in sources {
                let result: Result<[SourceEntry], Error>
                do {
                    result = .success(try await expander.expand(source))
                } catch is CancellationError {
                    return
                } catch {
                    result = .failure(error)
                }
                guard let self else { return }
                self.queueListed(source, result, folder: folder, options: options)
            }
            if let self, self.listingGeneration == generation { self.listing = nil }
        }
    }

    /// Returns once every pasted Playlist and Channel source has been listed into the Queue.
    public func waitUntilListed() async {
        while let listing {
            await listing.value
        }
    }

    private func queueListed(_ source: Source, _ result: Result<[SourceEntry], Error>, folder: URL, options: DownloadOptions) {
        if source.kind != .video, let index = listingSources.firstIndex(of: source) {
            listingSources.remove(at: index)
        }
        switch result {
        case .success(let entries):
            if entries.isEmpty { report("The \(source.kind.rawValue) \(source.url) has no videos.") }
            for entry in entries {
                queue.add(DownloadRequest(
                    url: entry.url, downloadFolder: folder, options: options,
                    origin: VideoOrigin(source: source, entry: entry)
                ))
            }
        case .failure:
            report("Couldn't list the videos of the \(source.kind.rawValue) \(source.url). Check the link, or try again later.")
        }
    }

    private func report(_ message: String) {
        errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
    }
}
