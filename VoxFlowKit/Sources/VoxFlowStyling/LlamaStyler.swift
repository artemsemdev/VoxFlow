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
        case unavailable
        case cancelled
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
        let startedAt = clock.now()
        let fallback = rules.styleSync(raw, options: options)
        guard !Task.isCancelled, limits.generationTimeout.isFinite, limits.generationTimeout > 0,
              options.generationDeadline?.isFinite != false else { return fallback }
        let end = min(startedAt + limits.generationTimeout, options.generationDeadline ?? .infinity)
        guard clock.now() < end else { return fallback }
        guard options.style != .verbatim, let system = StylePrompts.system(for: options.style) else { return fallback }
        let prepass = rules.styleSync(raw, options: StylingOptions(style: .casual, removeFillers: options.removeFillers, autoPunctuate: options.autoPunctuate))
        let words = prepass.text.wordCount
        guard limits.allowsLLM(words: words) else {
            Self.logger.notice("styling: skipping LLM, \(words) words is over the \(limits.maxInputWords)-word cap")
            return fallback
        }
        let request = ChatPrompt(system: system, user: prepass.text)
        let maxNewTokens = limits.maxNewTokens(forWords: words)
        let backend = backend, clock = clock, timeout = end - startedAt
        let race: RaceOutcome = await withTaskGroup(of: RaceOutcome.self) { group in
            // Readiness and generation share one absolute ceiling. Both backend operations must
            // cooperate with cancellation, as required by the existing structured timeout race.
            group.addTask {
                guard !Task.isCancelled else { return .cancelled }
                guard clock.now() < end else { return .timedOut }
                guard await backend.isReady() else { return .unavailable }
                guard !Task.isCancelled else { return .cancelled }
                guard clock.now() < end else { return .timedOut }
                do { return .output(try await backend.generate(request, maxNewTokens: maxNewTokens)) }
                catch { return .failed(error) }
            }
            group.addTask {
                let remaining = end - clock.now()
                guard remaining > 0 else { return .timedOut }
                do { try await clock.sleep(for: remaining); return .timedOut }
                catch { return .cancelled }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        let output: String
        switch race {
        case .output(let text):
            guard !Task.isCancelled, clock.now() < end else { return fallback }
            output = text
        case .unavailable:
            Self.logger.notice("styling: skipping LLM, backend not ready")
            return fallback
        case .cancelled:
            return fallback
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
