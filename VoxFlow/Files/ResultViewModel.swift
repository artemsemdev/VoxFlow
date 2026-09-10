import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowStyling

protocol Pasteboard { func setString(_ string: String) }
protocol FileRevealing { func reveal(_ url: URL) }

/// The transcript result screen (design 2f / MW-06r).
@Observable @MainActor
final class ResultViewModel {
    let document: TranscriptDocument
    let autoDetectedLanguage: Bool
    /// The catalog's display name for `document.modelID` (falls back to the raw id when the model
    /// isn't in the catalog — e.g. an older transcript) — resolved by the caller, not here, since
    /// `ResultViewModel` has no `ModelCatalog` dependency of its own (M1).
    let modelDisplayName: String
    var format: OutputFormat { didSet { rerender() } }
    var timestamps: Bool { didSet { rerender() } }
    var searchText = ""
    /// "Apply {Style} cleanup" (design 2f, plan ruling 6) — off by default (the auto-export already
    /// wrote the raw transcript). Rule-based only: a file transcript can run to thousands of
    /// segments, and 2f promises "instant, no re-processing" — the LLM never runs here.
    var applyCleanup = false { didSet { rerender() } }
    private(set) var rendered = ""
    private(set) var savedURL: URL?
    private(set) var exportMessage: String?

    private let makeExporter: () -> TranscriptExporter
    private let cleanupStyle: TextStyle
    private let cleanupOptions: StylingOptions
    private let pasteboard: any Pasteboard
    private let revealer: any FileRevealing
    /// Backs `cleanedDocument`: filled on first use, not `lazy` — `@Observable` classes can't have
    /// a `lazy` stored property (the synthesized accessors need to mutate self from a non-mutating
    /// getter), so this is `@ObservationIgnored` and the caching happens by hand in the computed
    /// property below.
    @ObservationIgnored private var cleanedCache: TranscriptDocument?

    init(document: TranscriptDocument, format: OutputFormat, timestamps: Bool, autoDetectedLanguage: Bool, modelDisplayName: String,
         savedURL: URL?, exporter: @escaping () -> TranscriptExporter, cleanupStyle: TextStyle, cleanupOptions: StylingOptions,
         pasteboard: any Pasteboard, revealer: any FileRevealing) {
        self.document = document
        self.format = format
        self.timestamps = timestamps
        self.autoDetectedLanguage = autoDetectedLanguage
        self.modelDisplayName = modelDisplayName
        self.savedURL = savedURL
        self.makeExporter = exporter
        self.cleanupStyle = cleanupStyle
        self.cleanupOptions = cleanupOptions
        self.pasteboard = pasteboard
        self.revealer = revealer
        if let savedURL { exportMessage = "Saved to \(Self.abbreviate(savedURL))" }
        rerender()
    }

    /// "Apply {defaultStyle.displayName} cleanup" — the canvas sample shows "Apply Casual cleanup"
    /// because Casual is the default style; a different global default reads its own name here.
    var cleanupLabel: String { "Apply \(cleanupStyle.displayName) cleanup" }

    /// `document` with every segment's text rewritten by `RuleStyler` (fillers/auto-punctuate per
    /// the global toggles, then the tone rules) — computed once and cached on first access, not on
    /// every `applyCleanup` toggle back to `true` (start/end/confidence are unchanged, so cleanup
    /// never needs to re-run once `document` itself is fixed).
    var cleanedDocument: TranscriptDocument {
        if let cleanedCache { return cleanedCache }
        let styler = RuleStyler()
        let cleanedSegments = document.transcript.segments.map { segment -> TranscriptSegment in
            let cleanedText = styler.styleSync(segment.text, options: cleanupOptions).text
            // `TranscriptSegment.init?` only fails when `end < start`, which cleanup never changes
            // (only `text` is rewritten) — the `?? segment` is unreachable in practice but keeps
            // this honest about the failable initializer instead of force-unwrapping it.
            return TranscriptSegment(start: segment.start, end: segment.end, text: cleanedText, confidence: segment.confidence) ?? segment
        }
        let cleaned = TranscriptDocument(sourceURL: document.sourceURL,
                                         transcript: Transcript(segments: cleanedSegments, language: document.transcript.language),
                                         modelID: document.modelID, audioDuration: document.audioDuration,
                                         processingTime: document.processingTime, createdAt: document.createdAt)
        cleanedCache = cleaned
        return cleaned
    }

    /// What the view renders/exports/searches: the cleaned document while `applyCleanup` is on,
    /// the raw `document` otherwise.
    var activeDocument: TranscriptDocument { applyCleanup ? cleanedDocument : document }

    /// (1-based transcript position, segment) pairs matching `searchText`, read from `activeDocument`
    /// so a checked "Apply {Style} cleanup" is what search matches against — `activeDocument.transcript.segments`
    /// is enumerated exactly once, so a row's number reflects its real position even when two
    /// segments have identical text (a `firstIndex(of:)` lookup per row would find the same — wrong —
    /// position for both; M2).
    var visibleIndexedSegments: [(index: Int, segment: TranscriptSegment)] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let indexed = activeDocument.transcript.segments.enumerated().map { (index: $0.offset + 1, segment: $0.element) }
        guard !needle.isEmpty else { return indexed }
        return indexed.filter { $0.segment.text.localizedCaseInsensitiveContains(needle) }
    }

    var visibleSegments: [TranscriptSegment] { visibleIndexedSegments.map(\.segment) }

    /// "1:32:10 · 13,842 words · EN (auto) · Whisper large-v3-turbo · took 4 min 12 s on this Mac"
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
        return "\(TimeCode.short(document.audioDuration)) · \(words) words · \(language) · \(modelDisplayName) · took \(Self.took(document.processingTime)) on this Mac"
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
        let url = try makeExporter().export(activeDocument, format: other, timestamps: timestamps)
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

    private func rerender() { rendered = TranscriptRenderer.render(activeDocument, format: format, timestamps: timestamps) }

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
