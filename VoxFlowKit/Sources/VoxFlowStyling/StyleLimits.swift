import Foundation
import NaturalLanguage
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
        guard Double(outWords) >= 0.3 * Double(inWords), Double(outWords) <= 3.0 * Double(inWords) else { return false }
        // A prompt is not a guarantee: the local model can translate while rewriting a tone.
        // Compare the actual texts, independently of Whisper's audio-language guess. A changed
        // or unidentifiable language falls back to rules; this check runs entirely on-device.
        guard let sourceLanguage = NLLanguageRecognizer.dominantLanguage(for: input),
              sourceLanguage != .undetermined,
              let outputLanguage = NLLanguageRecognizer.dominantLanguage(for: output) else { return false }
        return sourceLanguage == outputLanguage
    }
}
