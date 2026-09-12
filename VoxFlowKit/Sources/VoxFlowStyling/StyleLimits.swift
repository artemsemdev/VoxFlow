import Foundation
import VoxFlowCore

/// Maximum LLM work per call. Live dictation also supplies the remaining processing deadline,
/// so readiness and generation can use less than this ceiling after a slow final speech window.
public struct StyleLimits: Sendable, Equatable {
    public var maxInputWords = 150
    public var generationTimeout: TimeInterval = 8
    public var maxNewTokensCap = 768
    public init() {}

    public func maxNewTokens(forWords words: Int) -> Int { min(words * 3 + 32, maxNewTokensCap) }
    public func allowsLLM(words: Int) -> Bool { words > 0 && words <= maxInputWords }
}

/// Ruling 2: what counts as a usable LLM answer.
public enum OutputValidator {
    public static func clean(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func isAcceptable(_ output: String, input: String) -> Bool {
        let outWords = output.wordCount, inWords = max(1, input.wordCount)
        guard outWords > 0, !output.contains("<|im_") else { return false }
        guard output != input else { return false }
        return Double(outWords) >= 0.3 * Double(inWords) && Double(outWords) <= 3.0 * Double(inWords)
    }
}
