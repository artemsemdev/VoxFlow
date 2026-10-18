import Foundation

/// One chat turn for a style rewrite: a system instruction plus the user's text.
public struct ChatPrompt: Sendable, Equatable {
    public var system: String
    public var user: String
    public init(system: String, user: String) { self.system = system; self.user = user }
}

public enum LLMError: Error, Equatable, Sendable {
    case backendBusy
    case modelNotLoaded
    case modelLoadFailed(String)
    case promptTooLong(tokens: Int, limit: Int)
    case tokenizationFailed
    case decodeFailed(code: Int32)
    case cancelled
}

/// Anything that can answer a chat prompt with generated text. `VoxFlowStyling` talks to this;
/// the llama.cpp implementation lives in `VoxFlowLLM`, the app's lazy loader wraps it.
public protocol LLMBackend: Sendable {
    /// `true` only when a model is loaded and a request would run now — the styler never waits.
    func isReady() async -> Bool
    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String
}

/// An `LLMBackend` whose model can be loaded and unloaded by a lifecycle owner.
public protocol StyleEngine: LLMBackend {
    func load(modelAt url: URL) async throws
    func unload() async
}
