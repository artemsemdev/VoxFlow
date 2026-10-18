import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowLLM

/// Preflight failures must not initialize GPU resources. Real model loading is integration-tested.
@Suite("LlamaEngine")
struct LlamaEngineTests {
    private enum Probe: Error { case backendReached }

    @Test("missing, directory and non-file model URLs fail before native backend preparation")
    func invalidPathsDoNotPrepareBackend() async {
        let directory = TemporaryDirectory()
        for url in [directory.file("missing.gguf"), directory.url, URL(string: "https://example.invalid/model.gguf")!] {
            let engine = LlamaEngine(beforeBackendPreparation: { throw Probe.backendReached })
            await #expect(throws: LLMError.modelLoadFailed(url.path)) { try await engine.load(modelAt: url) }
            #expect(!(await engine.isReady()))
        }
    }

    @Test("a readable regular file or symlink reaches native preparation", arguments: [false, true])
    func regularFileReachesBackend(symlink: Bool) async throws {
        let directory = TemporaryDirectory()
        var url = directory.file("model.gguf")
        try Data("test fixture".utf8).write(to: url)
        if symlink {
            let link = directory.file("linked.gguf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            url = link
        }
        let engine = LlamaEngine(beforeBackendPreparation: { throw Probe.backendReached })
        await #expect(throws: Probe.backendReached) { try await engine.load(modelAt: url) }
    }

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
