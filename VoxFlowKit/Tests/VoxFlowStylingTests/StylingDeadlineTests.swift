import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowStyling

@Suite("Styling deadline", .timeLimit(.minutes(1)))
struct StylingDeadlineTests {
    private let raw = "we should meet on thursday afternoon"
    private func options(deadline: TimeInterval?) -> StylingOptions {
        StylingOptions(style: .formal, removeFillers: true, autoPunctuate: true,
                       generationDeadline: deadline)
    }

    @Test("expired or invalid deadlines skip generation", arguments: [0.0, -1.0, .infinity, .nan])
    func expiredDeadline(deadline: TimeInterval) async throws {
        let backend = FakeLLMBackend(reply: "Could we please meet on Thursday afternoon?")
        let opts = options(deadline: deadline)
        let result = try await LlamaStyler(backend: backend, clock: FakeClock()).style(raw, options: opts)
        #expect(await backend.prompts.isEmpty)
        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("remaining deadline caps the existing generation ceiling", arguments: [2.0, 20.0])
    func remainingBudget(deadline: TimeInterval) async throws {
        let backend = FakeLLMBackend(reply: "ignored")
        await backend.set(hangs: true)
        let clock = RecordingDeadlineClock()
        let opts = options(deadline: deadline)
        let task = Task { try await LlamaStyler(backend: backend, clock: clock).style(raw, options: opts) }
        await clock.base.waitForSleepers(1)
        #expect(clock.requests == [min(8, deadline)])
        // Release both the old ceiling and the new bounded timer so RED never hangs.
        await clock.base.advance(by: 8)
        #expect(try await task.value == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("a suspended readiness call is cancelled at the same deadline")
    func readinessIsBounded() async throws {
        let clock = FakeClock()
        let backend = FakeLLMBackend(reply: "ignored")
        let opts = options(deadline: 2)
        let task = Task {
            try await LlamaStyler(backend: WaitingReadinessBackend(base: backend, clock: clock), clock: clock)
                .style(raw, options: opts)
        }
        await clock.waitForSleepers(2)
        await clock.advance(by: 2)
        #expect(try await task.value == RuleStyler().styleSync(raw, options: opts))
        #expect(await backend.prompts.isEmpty)
        #expect(clock.sleeperCount == 0)
    }

    @Test("a reply arriving at or after the deadline is rejected", arguments: [2.0, 3.0])
    func rejectsLateReply(elapsed: Double) async throws {
        let clock = FakeClock()
        let opts = options(deadline: 2)
        let result = try await LlamaStyler(backend: LateReplyBackend(clock: clock, elapsed: elapsed), clock: clock)
            .style(raw, options: opts)
        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }

    @Test("a cancelled caller starts no backend work")
    func cancelledCaller() async throws {
        let start = Gate(), backend = FakeLLMBackend(reply: "ignored")
        let opts = options(deadline: 2)
        let task = Task {
            await start.wait()
            return try await LlamaStyler(backend: backend, clock: FakeClock()).style(raw, options: opts)
        }
        task.cancel()
        await start.open()
        #expect(try await task.value == RuleStyler().styleSync(raw, options: opts))
        #expect(await backend.prompts.isEmpty)
    }

    @Test("readiness cannot spend the deadline and then start generation")
    func readinessSpendsBudget() async throws {
        let clock = FakeClock()
        let backend = FakeLLMBackend(reply: "Could we please meet on Thursday afternoon?")
        let delaying = AdvancingReadinessBackend(base: backend, clock: clock)
        let opts = options(deadline: 2)
        let result = try await LlamaStyler(backend: delaying, clock: clock).style(raw, options: opts)
        #expect(await backend.prompts.isEmpty)
        #expect(result == RuleStyler().styleSync(raw, options: opts))
    }
}

private final class RecordingDeadlineClock: MonotonicClock {
    let base = FakeClock()
    private let recorded = Mutex<[TimeInterval]>([])
    var requests: [TimeInterval] { recorded.withLock { $0 } }
    func now() -> TimeInterval { base.now() }
    func sleep(for seconds: TimeInterval) async throws {
        recorded.withLock { $0.append(seconds) }
        try await base.sleep(for: seconds)
    }
}

private struct AdvancingReadinessBackend: LLMBackend {
    let base: FakeLLMBackend
    let clock: FakeClock
    func isReady() async -> Bool { await clock.advance(by: 3); return true }
    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        try await base.generate(prompt, maxNewTokens: maxNewTokens)
    }
}

private struct WaitingReadinessBackend: LLMBackend {
    let base: FakeLLMBackend
    let clock: FakeClock
    func isReady() async -> Bool {
        do { try await clock.sleep(for: 100); return true }
        catch { return false }
    }
    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        try await base.generate(prompt, maxNewTokens: maxNewTokens)
    }
}

private struct LateReplyBackend: LLMBackend {
    let clock: FakeClock
    let elapsed: Double
    func isReady() async -> Bool { true }
    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        await clock.advance(by: elapsed)
        return "Could we please meet on Thursday afternoon?"
    }
}
