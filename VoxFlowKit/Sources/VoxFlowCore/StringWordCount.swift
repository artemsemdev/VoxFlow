import Foundation

/// The one word-count implementation the dictation pipeline shares: the HUD ("Inserted 12 words"),
/// `DictationResult`, and the History row all need to agree, or the same number reads differently in
/// two places a user can see side by side (design MW-02).
public extension String {
    var wordCount: Int { split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}
