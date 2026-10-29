import Foundation

/// What the custom Naming pattern field shows under it.
public enum CustomNamePreview: Equatable, Sendable {
    /// The example path inside the Download folder, e.g. `Some Channel/My Video.mp4`.
    case example(String)
    /// Why the template cannot be used, in a plain sentence.
    case invalid(String)
}

/// Renders the live preview of a custom Naming pattern offline: yt-dlp evaluates the same details
/// line a download prints, from sample metadata (`--load-info-json`, no network), so the preview
/// and the real file name use one template language and yt-dlp's own validation.
public struct CustomNamePreviewer: Sendable {
    public var runner: YtDlpRunner

    public init(runner: YtDlpRunner) {
        self.runner = runner
    }

    /// The sample video: "My Video" by "Some Channel", uploaded 2026-10-12, 1 of 12 in "My Playlist".
    static let sample = VideoDetails(id: "dQw4w9WgXcQ", title: "My Video", channel: "Some Channel", uploadDate: "20261012")
    static let sampleOrigin = VideoOrigin(
        sourceKind: .playlist, videoID: sample.id, title: sample.title, channel: sample.channel,
        channelName: "Some Channel", playlistTitle: "My Playlist", playlistIndex: 1, playlistCount: 12
    )

    public func preview(_ template: String, format: Format) async -> CustomNamePreview {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Type a pattern in yt-dlp's output template language, e.g. \(CustomNamingPattern.starter)")
        }
        let request = DownloadRequest(
            url: Source.video(id: Self.sample.id).url, downloadFolder: URL(fileURLWithPath: "/"),
            options: DownloadOptions(format: format, quality: .best, naming: .custom, customPattern: template),
            origin: Self.sampleOrigin
        )
        let infoFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-preview-\(UUID().uuidString).info.json")
        defer { try? FileManager.default.removeItem(at: infoFile) }
        do {
            try Self.sampleInfoJSON.write(to: infoFile)
            // `before_dl` never fires while simulating, so the preview prints at the `video` stage.
            let arguments = ["--load-info-json", infoFile.path, "--simulate", "--print", YtDlpOutputTemplates.details(request.options)]
                + CustomNamingPattern.originMetadata(request)
            var rendered: VideoDetails?
            for try await update in runner.run(arguments) {
                switch update {
                case .event(.details(let video)): rendered = video
                case .event: break
                case .exited(let exit):
                    if let rendered, exit.succeeded {
                        return .example(request.namePlan(for: rendered).relativePath(
                            videoID: rendered.id, fileExtension: request.expectedFileExtension, withIDSuffix: false
                        ))
                    }
                    return .invalid(Self.reason(stderr: exit.stderr))
                }
            }
        } catch {}
        return .invalid("Couldn't preview the pattern: yt-dlp did not run.")
    }

    /// yt-dlp's reason from a usage error such as
    /// `yt-dlp: error: invalid video print template "...": incomplete format key`. The quoted
    /// template and any `at index N` are YT4S's internal form, so they are left out.
    static func reason(stderr: String) -> String {
        guard let line = stderr.split(whereSeparator: \.isNewline).last(where: { $0.contains("error: ") }) else {
            return "Couldn't preview the pattern."
        }
        var reason = String(line)
        if let quoteEnd = reason.range(of: "\": ", options: .backwards) {
            reason = String(reason[quoteEnd.upperBound...])
        } else if let error = reason.range(of: "error: ") {
            reason = String(reason[error.upperBound...])
        }
        if let index = reason.range(of: #" at index \d+$"#, options: .regularExpression) {
            reason.removeSubrange(index)
        }
        return "Invalid pattern: \(reason)"
    }

    /// A minimal info dict yt-dlp accepts offline: one progressive format, so format selection
    /// succeeds without fetching anything.
    static var sampleInfoJSON: Data {
        let info: [String: Any] = [
            "id": sample.id,
            "title": sample.title,
            "fulltitle": sample.title,
            "channel": sample.channel ?? "",
            "uploader": sample.channel ?? "",
            "channel_id": "UCuAXFkgsw1L7xaCfnd5JJOw",
            "uploader_id": "@SomeChannel",
            "upload_date": sample.uploadDate ?? "",
            "timestamp": 1_760_270_400,
            "duration": 212,
            "view_count": 1_234_567,
            "like_count": 12_345,
            "description": "",
            "extractor": "youtube",
            "extractor_key": "Youtube",
            "webpage_url": Source.video(id: sample.id).url,
            "original_url": Source.video(id: sample.id).url,
            "_type": "video",
            "formats": [["format_id": "18", "ext": "mp4", "url": "https://localhost/yt4s-preview", "protocol": "https"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
    }
}
