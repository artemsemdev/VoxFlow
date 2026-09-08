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
    var metaLine: String {
        let words = Self.wordCountFormatter.string(from: NSNumber(value: document.wordCount)) ?? "\(document.wordCount)"
        let language = (document.transcript.language ?? "auto").uppercased() + (autoDetectedLanguage ? " (auto)" : "")
        return "\(TimeCode.short(document.audioDuration)) · \(words) words · \(language) · \(document.modelID) · took \(Self.took(document.processingTime)) on this Mac"
    }

    /// A fixed `en_US_POSIX`-style grouping ("13,842") regardless of the system locale — the design
    /// specifies this exact formatting, not whatever separator the user's region uses.
    private static let wordCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
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

    func reveal() { if let savedURL { revealer.reveal(savedURL) } }

    private func rerender() { rendered = TranscriptRenderer.render(document, format: format, timestamps: timestamps) }

    static func took(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
