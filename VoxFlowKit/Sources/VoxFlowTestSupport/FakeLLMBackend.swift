import Foundation
import VoxFlowCore

/// Scripted `StyleEngine`: records prompts, answers with `reply`, can be made not-ready, throwing, or
/// hang until `release()` (for timeout tests — pair with `FakeClock`).
public actor FakeLLMBackend: StyleEngine {
    public var ready: Bool
    public var reply: String
    public var error: LLMError?
    public var hangs = false
    public private(set) var prompts: [ChatPrompt] = []
    public private(set) var maxTokens: [Int] = []
    public private(set) var loadedURLs: [URL] = []
    public private(set) var unloadCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    public init(ready: Bool = true, reply: String = "") { self.ready = ready; self.reply = reply }

    public func set(ready: Bool) { self.ready = ready }
    public func set(reply: String) { self.reply = reply }
    public func set(error: LLMError?) { self.error = error }
    public func set(hangs: Bool) { self.hangs = hangs; released = false }
    public func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }

    public func isReady() async -> Bool { ready }

    public func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        prompts.append(prompt); maxTokens.append(maxNewTokens)
        if let error { throw error }
        if hangs && !released {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: { Task { await self.release() } }
            if Task.isCancelled { throw LLMError.cancelled }
        }
        return reply
    }

    public func load(modelAt url: URL) async throws { loadedURLs.append(url); ready = true }
    public func unload() async { unloadCount += 1; ready = false }
}
