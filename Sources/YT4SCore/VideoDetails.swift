import Foundation

extension YtDlpOutputTemplates {
    /// `--print before_dl:` once per video, once it is looked up and before any byte downloads:
    /// what naming needs. Fields: id, title (JSON), the video's channel (JSON), upload date
    /// (`YYYYMMDD`). Flat listing never has the upload date, hence this line.
    public static let details = "before_dl:" + detailsLine

    /// The `details` template without its `before_dl:` stage, so a preview can print it at another stage.
    static let detailsLine = "YT4S-DETAILS\t%(id)s\t%(title)j\t%(channel,uploader)j\t%(upload_date)s"

    /// The details line for `options`: with a custom Naming pattern, yt-dlp also renders the
    /// template as the line's last field (see `CustomNamingTemplate`).
    static func details(_ options: DownloadOptions) -> String {
        guard options.naming == .custom else { return detailsLine }
        return detailsLine + "\t" + CustomNamingTemplate(options.customTemplate).printTemplate
    }
}

/// What naming needs to know about one video once yt-dlp has looked it up.
public struct VideoDetails: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The video's own channel.
    public var channel: String?
    /// Upload date as yt-dlp gives it, `YYYYMMDD`.
    public var uploadDate: String?
    /// The custom Naming pattern as yt-dlp rendered it for this video (folders separated by
    /// `CustomNamingTemplate.folderSeparator`), when the pattern is custom.
    public var customName: String?

    public init(id: String, title: String, channel: String? = nil, uploadDate: String? = nil, customName: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploadDate = uploadDate
        self.customName = customName
    }

    /// Parses the tab-separated fields of a `YT4S-DETAILS` line (kind first).
    init?(fields: [String]) {
        guard fields.count >= 5, fields[0] == "YT4S-DETAILS", !fields[1].isEmpty, fields[1] != "NA",
              let title = Self.text(fields[2])
        else { return nil }
        self.init(
            id: fields[1],
            title: title,
            channel: Self.text(fields[3]),
            uploadDate: fields[4] == "NA" || fields[4].isEmpty ? nil : fields[4],
            // The rendered custom name may itself contain tabs.
            customName: fields.count > 5 ? fields[5...].joined(separator: "\t") : nil
        )
    }

    /// A `j`-converted field: a JSON string, or `NA` when missing.
    private static func text(_ field: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(field.utf8))
    }
}
