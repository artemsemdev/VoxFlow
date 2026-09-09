import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport

/// Covers `FakeLLMBackend` itself: Task 2's timeout tests depend on it, so a race here would surface
/// there as a mysterious hang rather than a failure in this suite.
@Suite("FakeLLMBackend")
struct FakeLLMBackendTests {
    @Test("records every prompt and maxNewTokens across calls, in order")
    func recordsCalls() async throws {
        let fake = FakeLLMBackend(reply: "styled")
        _ = try await fake.generate(ChatPrompt(system: "s1", user: "u1"), maxNewTokens: 8)
        _ = try await fake.generate(ChatPrompt(system: "s2", user: "u2"), maxNewTokens: 16)
        #expect(await fake.prompts == [ChatPrompt(system: "s1", user: "u1"), ChatPrompt(system: "s2", user: "u2")])
        #expect(await fake.maxTokens == [8, 16])
    }

    @Test("release() completes a pending hanging generate with the configured reply")
    func releaseCompletesHangingGenerate() async throws {
        let fake = FakeLLMBackend(reply: "styled")
        await fake.set(hangs: true)
        let task = Task { try await fake.generate(ChatPrompt(system: "s", user: "u"), maxNewTokens: 8) }
        // The actor runs generate() synchronously from `prompts.append` through registering the
        // continuation in `waiters` — there is no suspension point between them — so observing
        // `prompts` non-empty from outside guarantees the waiter is already registered too.
        while await fake.prompts.isEmpty { await Task.yield() }
        await fake.release()
        #expect(try await task.value == "styled")
    }

    @Test("release() called before generate() is invoked still lets it return promptly (sticky)")
    func releaseBeforeGenerateIsSticky() async throws {
        let fake = FakeLLMBackend(reply: "styled")
        await fake.set(hangs: true)
        await fake.release()   // nothing is waiting yet — must not be lost
        let result = try await fake.generate(ChatPrompt(system: "s", user: "u"), maxNewTokens: 8)
        #expect(result == "styled")
    }

    @Test("set(hangs:) re-arms the hang after a release — the next generate() genuinely blocks again")
    func setHangsResetsReleased() async throws {
        let fake = FakeLLMBackend(reply: "second")
        await fake.set(hangs: true)
        await fake.release()
        await fake.set(hangs: true)   // must reset `released`, or the generate() below would return at once

        let task = Task { try await fake.generate(ChatPrompt(system: "s", user: "u"), maxNewTokens: 8) }
        while await fake.prompts.isEmpty { await Task.yield() }
        // If `released` had not been reset, generate() already returned "second" and this cancel is a
        // no-op on a finished task — `task.value` would return normally instead of throwing, failing
        // the expectation below. If it correctly re-armed, generate() is still suspended on its
        // continuation and cancelling it resolves through the same cancelled path as any other hang.
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
    }

    @Test("cancelling the task awaiting a hanging generate throws LLMError.cancelled")
    func cancellingHangingGenerateThrowsCancelled() async throws {
        let fake = FakeLLMBackend(reply: "styled")
        await fake.set(hangs: true)
        let task = Task { try await fake.generate(ChatPrompt(system: "s", user: "u"), maxNewTokens: 8) }
        while await fake.prompts.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: LLMError.cancelled) { try await task.value }
    }
}
