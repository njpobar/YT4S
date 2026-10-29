import Foundation

extension YtDlpOutputTemplates {
    /// `--print before_dl:` once per video, once it is looked up and before any byte downloads:
    /// what naming needs. Fields: id, title (JSON), the video's channel (JSON), upload date
    /// (`YYYYMMDD`). Flat listing never has the upload date, hence this line.
    public static let details = "before_dl:YT4S-DETAILS\t%(id)s\t%(title)j\t%(channel,uploader)j\t%(upload_date)s"
}

/// What naming needs to know about one video once yt-dlp has looked it up.
public struct VideoDetails: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The video's own channel.
    public var channel: String?
    /// Upload date as yt-dlp gives it, `YYYYMMDD`.
    public var uploadDate: String?

    public init(id: String, title: String, channel: String? = nil, uploadDate: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploadDate = uploadDate
    }

    /// Parses the tab-separated fields of a `YT4S-DETAILS` line (kind first).
    init?(fields: [String]) {
        guard fields.count == 5, fields[0] == "YT4S-DETAILS", !fields[1].isEmpty, fields[1] != "NA",
              let title = Self.text(fields[2])
        else { return nil }
        self.init(
            id: fields[1],
            title: title,
            channel: Self.text(fields[3]),
            uploadDate: fields[4] == "NA" || fields[4].isEmpty ? nil : fields[4]
        )
    }

    /// A `j`-converted field: a JSON string, or `NA` when missing.
    private static func text(_ field: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(field.utf8))
    }
}
