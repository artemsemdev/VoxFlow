/// Transcript output formats (design 1c Files › Output format, 2f).
public enum OutputFormat: String, CaseIterable, Sendable, Codable {
    case txt, srt, vtt, json, md

    public static let `default`: OutputFormat = .txt

    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }

    /// TXT and MD can be written with or without per-segment timestamps; the others always carry them.
    public var supportsTimestampToggle: Bool { self == .txt || self == .md }

    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "txt", "text": self = .txt
        case "srt": self = .srt
        case "vtt", "webvtt": self = .vtt
        case "json": self = .json
        case "md", "markdown": self = .md
        default: return nil
        }
    }
}
