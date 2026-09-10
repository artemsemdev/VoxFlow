import Foundation
import OSLog
import VoxFlowCore

/// LLM-backed `TextStyler` (ADR-007): rule pre-pass → LLM tone rewrite → validation, falling back to
/// `RuleStyler` with the requested tone on every failure path. Never throws — a styling failure must
/// never lose a dictation.
public struct LlamaStyler: TextStyler, Sendable {
    /// One result from the generate-vs-timeout race (final review M8): keeps "the backend threw" and
    /// "the timeout won" distinguishable so each can be logged with its own reason.
    private enum RaceOutcome {
        case output(String)
        case failed(any Error)
        case timedOut
    }

    public let backend: any LLMBackend
    public let rules: RuleStyler
    public let limits: StyleLimits
    public let clock: any MonotonicClock
    private static let logger = Logger(subsystem: "dev.artemsem.voxflow", category: "styling")

    public init(backend: any LLMBackend, rules: RuleStyler = RuleStyler(), limits: StyleLimits = StyleLimits(), clock: any MonotonicClock) {
        self.backend = backend; self.rules = rules; self.limits = limits; self.clock = clock
    }

    public func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
        let fallback = rules.styleSync(raw, options: options)
        guard options.style != .verbatim, let system = StylePrompts.system(for: options.style) else { return fallback }
        let prepass = rules.styleSync(raw, options: StylingOptions(style: .casual, removeFillers: options.removeFillers, autoPunctuate: options.autoPunctuate))
        let words = prepass.text.wordCount
        guard limits.allowsLLM(words: words) else {
            Self.logger.notice("styling: skipping LLM, \(words) words is over the \(limits.maxInputWords)-word cap")
            return fallback
        }
        guard await backend.isReady() else {
            Self.logger.notice("styling: skipping LLM, backend not ready")
            return fallback
        }

        let request = ChatPrompt(system: system, user: prepass.text)
        let maxNewTokens = limits.maxNewTokens(forWords: words)
        let backend = backend, clock = clock, timeout = limits.generationTimeout
        let race: RaceOutcome = await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask {
                do { return .output(try await backend.generate(request, maxNewTokens: maxNewTokens)) }
                catch { return .failed(error) }
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        let output: String
        switch race {
        case .output(let text):
            output = text
        case .failed(let error):
            Self.logger.error("styling: LLM generation failed: \(String(describing: error))")
            return fallback
        case .timedOut:
            Self.logger.notice("styling: LLM generation exceeded the \(timeout)s budget")
            return fallback
        }

        let cleaned = OutputValidator.clean(output)
        guard OutputValidator.isAcceptable(cleaned, input: prepass.text) else {
            Self.logger.notice("styling: LLM output failed validation, falling back to rules")
            return fallback
        }
        return StyledText(text: cleaned, fillersRemoved: prepass.fillersRemoved, cursorOffset: nil)
    }
}
