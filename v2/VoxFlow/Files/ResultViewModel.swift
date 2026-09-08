import Foundation
import VoxFlowCore
import VoxFlowFiles

protocol Pasteboard { func setString(_ string: String) }
protocol FileRevealing { func reveal(_ url: URL) }

/// The transcript result screen (design 2f / MW-06r).
@Observable @MainActor
final class ResultViewModel {
    let document: TranscriptDocument
    let autoDetectedLanguage: Bool
    var format: OutputFormat { didSet { rerender() } }
    var timestamps: Bool { didSet { rerender() } }
    var searchText = ""
    private(set) var rendered = ""
    private(set) var savedURL: URL?
    private(set) var exportMessage: String?

    private let makeExporter: () -> TranscriptExporter
    private let pasteboard: any Pasteboard
    private let revealer: any FileRevealing

    init(document: TranscriptDocument, format: OutputFormat, timestamps: Bool, autoDetectedLanguage: Bool, savedURL: URL?,
         exporter: @escaping () -> TranscriptExporter, pasteboard: any Pasteboard, revealer: any FileRevealing) {
        self.document = document
        self.format = format
        self.timestamps = timestamps
        self.autoDetectedLanguage = autoDetectedLanguage
        self.savedURL = savedURL
        self.makeExporter = exporter
        self.pasteboard = pasteboard
        self.revealer = revealer
        if let savedURL { exportMessage = "Saved to \(Self.abbreviate(savedURL))" }
        rerender()
    }

    var visibleSegments: [TranscriptSegment] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return document.transcript.segments }
        return document.transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    /// "1:32:10 · 13,842 words · EN (auto) · whisper-large-v3-turbo · took 4 min 12 s on this Mac"
    /// When the language is unknown (nil) under auto-detect, the language field is just "AUTO" —
    /// not "AUTO (auto)", which the code+suffix would otherwise produce.
    var metaLine: String {
        let words = Self.wordCountFormatter.string(from: NSNumber(value: document.wordCount)) ?? "\(document.wordCount)"
        let language: String
        if let code = document.transcript.language {
            language = code.uppercased() + (autoDetectedLanguage ? " (auto)" : "")
        } else {
            language = "AUTO"
        }
        return "\(TimeCode.short(document.audioDuration)) · \(words) words · \(language) · \(document.modelID) · took \(Self.took(document.processingTime)) on this Mac"
    }

    /// A fixed `en_US_POSIX` grouping ("13,842") regardless of the system locale — the design
    /// specifies this exact formatting, not whatever separator the user's region uses.
    private static let wordCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        return formatter
    }()

    var otherFormats: [OutputFormat] { OutputFormat.allCases.filter { $0 != format } }

    func copy() { pasteboard.setString(rendered) }

    @discardableResult
    func exportAlso(_ other: OutputFormat) throws -> URL {
        let url = try makeExporter().export(document, format: other, timestamps: timestamps)
        exportMessage = "Saved to \(Self.abbreviate(url))"
        return url
    }

    /// Surfaces a failure from an action the view attempted (`exportAlso`'s throw, or a failed
    /// `SavePanel.save`) as `exportMessage`, so it reads next to where "Saved to …" would otherwise
    /// show — never silently swallowed via `try?`.
    func report(error: Error) {
        exportMessage = "Couldn’t save: \(error.localizedDescription)"
    }

    func reveal() { if let savedURL { revealer.reveal(savedURL) } }

    private func rerender() { rendered = TranscriptRenderer.render(document, format: format, timestamps: timestamps) }

    static func took(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        // Compare against "home + /" so a sibling directory that merely shares `home` as a string
        // prefix (e.g. "/Users/artemsemenov2") isn't mistaken for a subdirectory of it.
        let prefix = home + "/"
        return path.hasPrefix(prefix) ? "~" + path.dropFirst(home.count) : path
    }
}
