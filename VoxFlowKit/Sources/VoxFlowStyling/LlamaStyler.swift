import Foundation
import VoxFlowCore

/// LLM-backed `TextStyler` (ADR-007): rule pre-pass → LLM tone rewrite → validation, falling back to
/// `RuleStyler` with the requested tone on every failure path. Never throws — a styling failure must
/// never lose a dictation.
public struct LlamaStyler: TextStyler, Sendable {
    public let backend: any LLMBackend
    public let rules: RuleStyler
    public let limits: StyleLimits
    public let clock: any MonotonicClock

    public init(backend: any LLMBackend, rules: RuleStyler = RuleStyler(), limits: StyleLimits = StyleLimits(), clock: any MonotonicClock) {
        self.backend = backend; self.rules = rules; self.limits = limits; self.clock = clock
    }

    public func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
        let fallback = rules.styleSync(raw, options: options)
        guard options.style != .verbatim, let system = StylePrompts.system(for: options.style) else { return fallback }
        let prepass = rules.styleSync(raw, options: StylingOptions(style: .casual, removeFillers: options.removeFillers, autoPunctuate: options.autoPunctuate))
        let words = prepass.text.wordCount
        guard limits.allowsLLM(words: words), await backend.isReady() else { return fallback }

        let request = ChatPrompt(system: system, user: prepass.text)
        let maxNewTokens = limits.maxNewTokens(forWords: words)
        let backend = backend, clock = clock, timeout = limits.generationTimeout
        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await backend.generate(request, maxNewTokens: maxNewTokens) }
            group.addTask { try? await clock.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output else { return fallback }
        let cleaned = OutputValidator.clean(output)
        guard OutputValidator.isAcceptable(cleaned, input: prepass.text) else { return fallback }
        return StyledText(text: cleaned, fillersRemoved: prepass.fillersRemoved, cursorOffset: nil)
    }
}
