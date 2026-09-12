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
    var segmentLength: SegmentLength = .sentences { didSet { cleanedCache = nil; updateCleanup() } }
    /// Rules render immediately; short transcripts can then improve with the shared local LLM.
    var applyCleanup = false { didSet { updateCleanup() } }
    private(set) var isCleaning = false
    private var cleanupRevision = 0
    private(set) var rendered = ""
    private(set) var savedURL: URL?
    private(set) var exportMessage: String?

    private let makeExporter: () -> TranscriptExporter
    private let cleanupStyle: TextStyle
    private let cleanupStyler: (any TextStyler)?
    private let cleanupClock: any MonotonicClock
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupGeneration = 0
    private let cleanupOptions: StylingOptions
    private let pasteboard: any Pasteboard
    private let revealer: any FileRevealing
    /// Backs `cleanedDocument`: filled on first use, not `lazy` — `@Observable` classes can't have
    /// a `lazy` stored property (the synthesized accessors need to mutate self from a non-mutating
    /// getter), so this is `@ObservationIgnored` and the caching happens by hand in the computed
    /// property below.
    @ObservationIgnored private var cleanedCache: (length: SegmentLength, document: TranscriptDocument)?
    @ObservationIgnored private var segmentedCache: [SegmentLength: TranscriptDocument] = [:]

    init(document: TranscriptDocument, format: OutputFormat, timestamps: Bool, autoDetectedLanguage: Bool, modelDisplayName: String,
         savedURL: URL?, exporter: @escaping () -> TranscriptExporter, cleanupStyle: TextStyle, cleanupOptions: StylingOptions,
         pasteboard: any Pasteboard, revealer: any FileRevealing,
         cleanupStyler: (any TextStyler)? = nil, cleanupClock: any MonotonicClock = SystemMonotonicClock()) {
        self.document = document
        self.format = format
        self.timestamps = timestamps
        self.autoDetectedLanguage = autoDetectedLanguage
        self.modelDisplayName = modelDisplayName
        self.savedURL = savedURL
        self.makeExporter = exporter
        self.cleanupStyle = cleanupStyle
        self.cleanupOptions = cleanupOptions
        self.cleanupStyler = cleanupStyler
        self.cleanupClock = cleanupClock
        self.pasteboard = pasteboard
        self.revealer = revealer
        if let savedURL { exportMessage = "Saved to \(Self.abbreviate(savedURL))" }
        rerender()
    }

    /// "Apply {defaultStyle.displayName} cleanup" — the canvas sample shows "Apply Casual cleanup"
    /// because Casual is the default style; a different global default reads its own name here.
    var cleanupLabel: String { "Apply \(cleanupStyle.displayName) cleanup" }

    /// Rules are cached first; a completed short-file rewrite replaces the cache atomically.
    /// Segment boundaries and confidence always belong to the selected source segmentation.
    var cleanedDocument: TranscriptDocument {
        // Async cache replacement must invalidate views observing segments or the word count.
        _ = cleanupRevision
        // Read the cache key even on a hit so SwiftUI observes the selected length for row refresh.
        if let cleanedCache, cleanedCache.length == segmentLength { return cleanedCache.document }
        let styler = RuleStyler()
        let cleanedSegments = segmentedDocument.transcript.segments.map { segment -> TranscriptSegment in
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
        cleanedCache = (segmentLength, cleaned)
        return cleaned
    }

    /// Invalidate before cancellation: even a backend that replies late cannot publish stale text.
    func cancelCleanup() {
        cleanupGeneration += 1
        cleanupTask?.cancel()
        isCleaning = false
    }

    func waitForCleanup() async { await cleanupTask?.value }

    private func updateCleanup() {
        cancelCleanup()
        let limits = StyleLimits()
        let canImprove = cleanupOptions.style != .verbatim && limits.allowsLLM(words: document.wordCount)
        // A retry starts from rules, so a newly unavailable model never leaves old LLM output.
        if applyCleanup, canImprove, cleanupStyler != nil { cleanedCache = nil }
        rerender()
        guard applyCleanup, canImprove, let cleanupStyler else { return }
        let generation = cleanupGeneration, length = segmentLength
        let source = segmentedDocument
        let output = cleanedDocument
        var options = cleanupOptions
        // One file budget, not eight seconds for each of as many as 150 segments.
        let deadline = min(options.generationDeadline ?? .infinity, cleanupClock.now() + limits.generationTimeout)
        options.generationDeadline = deadline
        let clock = cleanupClock
        isCleaning = true
        cleanupTask = Task { [weak self, output, options] in
            var output = output
            for (index, segment) in source.transcript.segments.enumerated() {
                guard !Task.isCancelled, clock.now() < deadline else { break }
                // LlamaStyler owns readiness, validation, contention and failure fallback.
                // Keep rules even if another injected styler throws.
                if let styled = try? await cleanupStyler.style(segment.text, options: options),
                   !Task.isCancelled, clock.now() < deadline {
                    output.transcript.segments[index].text = styled.text
                }
            }
            guard let self, !Task.isCancelled, self.cleanupGeneration == generation,
                  self.applyCleanup, self.segmentLength == length else { return }
            self.cleanedCache = (length, output)
            self.cleanupRevision += 1
            self.isCleaning = false
            self.rerender()
        }
    }

    private var segmentedDocument: TranscriptDocument {
        if let cached = segmentedCache[segmentLength] { return cached }
        let segmented = TranscriptSegmenter.resegment(document, length: segmentLength)
        segmentedCache[segmentLength] = segmented
        return segmented
    }

    /// Preview, search and every export share the selected segmentation and optional cleanup.
    var activeDocument: TranscriptDocument { applyCleanup ? cleanedDocument : segmentedDocument }

    /// Timed formats use the canvas's cue columns; other formats preview their actual file text.
    var usesTimedPreview: Bool { format == .srt || format == .vtt }

    /// Search filters the preview only. Copy and export retain the complete active document.
    var previewText: String {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return rendered }
        var filtered = activeDocument
        filtered.transcript.segments = visibleSegments
        return TranscriptRenderer.render(filtered, format: format, timestamps: timestamps)
    }

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
        let count = activeDocument.wordCount
        let words = Self.wordCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
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
