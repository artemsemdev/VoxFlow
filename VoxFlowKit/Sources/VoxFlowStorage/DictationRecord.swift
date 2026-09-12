import Foundation
import VoxFlowCore

/// What the Flow Bar hands to storage after an insertion (design MW-02 row fields; audio is never stored).
public struct DictationDraft: Sendable, Equatable {
    public var text: String
    public var rawText: String
    public var appName: String?
    public var style: String?
    public var language: String?
    public var duration: TimeInterval
    public var createdAt: Date
    public var annotations: DictationAnnotations?

    public init(text: String, rawText: String, appName: String?, style: String?, language: String?, duration: TimeInterval,
                createdAt: Date, annotations: DictationAnnotations? = nil) {
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.style = style
        self.language = language
        self.duration = duration
        self.createdAt = createdAt
        self.annotations = annotations?.validated(for: rawText)
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
    /// True when this row could not be decoded (encrypted with no cipher available, or decryption
    /// failed) — `text`/`rawText` are empty; the History page renders it as "Encrypted — turn on
    /// 'Encrypt history at rest' to read" rather than the row disappearing or the whole list failing.
    public var isUnreadable: Bool
    public var annotations: DictationAnnotations?

    public init(id: Int64, text: String, rawText: String, appName: String?, style: String?, language: String?, duration: TimeInterval,
                words: Int, createdAt: Date, isUnreadable: Bool = false, annotations: DictationAnnotations? = nil) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.style = style
        self.language = language
        self.duration = duration
        self.words = words
        self.createdAt = createdAt
        self.isUnreadable = isUnreadable
        self.annotations = annotations?.validated(for: rawText)
    }

    public static func wordCount(_ text: String) -> Int { text.wordCount }
}
