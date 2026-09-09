import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowLLM

/// Exercises the real C-interop path without needing a model file installed: `llama_backend_init`,
/// the real `llama_model_load_from_file` call, and the box lifecycle on a load that fails.
@Suite("LlamaEngine")
struct LlamaEngineTests {
    @Test("load with a bogus path throws modelLoadFailed and leaves the engine not ready")
    func bogusPathLoadFails() async throws {
        let engine = LlamaEngine()
        let bogus = URL(fileURLWithPath: "/nonexistent/path/to/model.gguf")
        await #expect(throws: LLMError.modelLoadFailed(bogus.path)) { try await engine.load(modelAt: bogus) }
        #expect(!(await engine.isReady()))
    }

    @Test("generate after a failed load still throws modelNotLoaded")
    func generateAfterFailedLoadThrowsNotLoaded() async throws {
        let engine = LlamaEngine()
        let bogus = URL(fileURLWithPath: "/nonexistent/path/to/model.gguf")
        _ = try? await engine.load(modelAt: bogus)
        await #expect(throws: LLMError.modelNotLoaded) {
            try await engine.generate(ChatPrompt(system: "a", user: "b"), maxNewTokens: 8)
        }
    }
}
