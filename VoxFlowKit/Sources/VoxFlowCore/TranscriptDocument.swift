import Foundation

/// A finished file transcription plus the metadata the result view shows (design 2f).
public struct TranscriptDocument: Sendable, Equatable, Codable {
    public var sourceURL: URL
    public var transcript: Transcript
    public var modelID: String
    public var audioDuration: TimeInterval
    public var processingTime: TimeInterval
    public var createdAt: Date

    public init(sourceURL: URL, transcript: Transcript, modelID: String, audioDuration: TimeInterval,
                processingTime: TimeInterval, createdAt: Date) {
        self.sourceURL = sourceURL
        self.transcript = transcript
        self.modelID = modelID
        self.audioDuration = audioDuration
        self.processingTime = processingTime
        self.createdAt = createdAt
    }

    public var baseName: String { sourceURL.deletingPathExtension().lastPathComponent }
    public var wordCount: Int { transcript.wordCount }
}
