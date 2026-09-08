import Foundation
import VoxFlowCore

enum JSONWriter: TranscriptWriter {
    static let format = OutputFormat.json

    struct Segment: Encodable {
        let start: Double, end: Double, text: String, confidence: Double?
    }
    struct Payload: Encodable {
        let source: String, language: String?, model: String, duration: Double, processingTime: Double
        let createdAt: Date, words: Int, generator: String, segments: [Segment]
    }

    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        let payload = Payload(
            source: document.sourceURL.lastPathComponent, language: document.transcript.language,
            model: document.modelID, duration: document.audioDuration, processingTime: document.processingTime,
            createdAt: document.createdAt, words: document.wordCount, generator: "VoxFlow \(VoxFlowVersion.string)",
            segments: document.transcript.segments.map {
                Segment(start: $0.start, end: $0.end, text: TranscriptRenderer.cleanText($0), confidence: $0.confidence)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            preconditionFailure("TranscriptDocument is always encodable: \(error)")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
