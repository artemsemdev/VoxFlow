import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowLLM

extension Tag { @Tag static var requiresModel: Self }

@Suite(.tags(.requiresModel), .serialized)
struct LlamaEngineIntegrationTests {
    static var modelURL: URL? {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_STYLE_MODEL"] { return URL(fileURLWithPath: override) }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoxFlow/Models/qwen2.5-3b-instruct-q4_k_m.gguf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test("rewrites a fixture differently per tone (real model)",
          .enabled(if: Self.modelURL != nil, "Install the style model or set VOXFLOW_STYLE_MODEL to run real tone validation"))
    func rewritesPerTone() async throws {
        let url = try #require(Self.modelURL)
        let engine = LlamaEngine()
        do {
            try await engine.load(modelAt: url)
            #expect(await engine.isReady())
            let raw = "um so can we push the meeting to thursday afternoon i need the numbers from finance first"
            var outputs: [String] = []
            for system in ["Rewrite the user's text as clear, polite, professional language with complete sentences and no contractions. Reply with the rewritten text only.",
                           "Rewrite the user's text as a short relaxed chat message, lowercase is fine. Reply with the rewritten text only."] {
                let out = try await engine.generate(ChatPrompt(system: system, user: raw), maxNewTokens: 96)
                #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                outputs.append(out)
            }
            #expect(outputs[0] != outputs[1])
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
        #expect(!(await engine.isReady()))
    }

    @Test("generate without a model throws modelNotLoaded")
    func notLoaded() async {
        let engine = LlamaEngine()
        await #expect(throws: LLMError.modelNotLoaded) { try await engine.generate(ChatPrompt(system: "a", user: "b"), maxNewTokens: 8) }
    }
}
