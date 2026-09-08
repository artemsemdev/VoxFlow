import Foundation

/// What the Flow Bar hands to storage after an insertion (design MW-02 row fields; audio is never stored).
public struct DictationDraft: Sendable, Equatable {
    public var text: String
    public var rawText: String
    public var appName: String?
    public var style: String?
    public var language: String?
    public var duration: TimeInterval
    public var createdAt: Date

    public init(text: String, rawText: String, appName: String?, style: String?, language: String?, duration: TimeInterval, createdAt: Date) {
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.style = style
        self.language = language
        self.duration = duration
        self.createdAt = createdAt
    }
}

public struct DictationRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var text: String
    public var rawText: String
    public var appName: String?
    public var style: String?
    public var language: String?
    public var duration: TimeInterval
    public var words: Int
    public var createdAt: Date

    public init(id: Int64, text: String, rawText: String, appName: String?, style: String?, language: String?, duration: TimeInterval, words: Int, createdAt: Date) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.style = style
        self.language = language
        self.duration = duration
        self.words = words
        self.createdAt = createdAt
    }

    public static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}
