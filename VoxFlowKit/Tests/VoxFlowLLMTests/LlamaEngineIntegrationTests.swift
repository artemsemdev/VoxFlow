import Foundation
import Testing
import VoxFlowCore
import VoxFlowStyling
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

    @Test("Russian dictation stays Russian after every tone (real model)",
          .enabled(if: Self.modelURL != nil, "Install the style model or set VOXFLOW_STYLE_MODEL to run real language validation"))
    func russianStylesKeepLanguage() async throws {
        let engine = LlamaEngine()
        do {
            try await engine.load(modelAt: #require(Self.modelURL))
            let styler = LlamaStyler(backend: engine, clock: SystemMonotonicClock())
            let raw = "встреча уже запланирована на завтра и все участники получили приглашения"
            for style: TextStyle in [.formal, .casual, .veryCasual] {
                let result = try await styler.style(raw, options: StylingOptions(style: style, removeFillers: true, autoPunctuate: true))
                #expect(result.text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil)
                #expect(result.text.range(of: "[A-Za-z]", options: .regularExpression) == nil)
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }

    @Test("Casual keeps the source words with the real model",
          .enabled(if: Self.modelURL != nil, "Install the style model or set VOXFLOW_STYLE_MODEL to run real word-preservation validation"))
    func casualKeepsWords() async throws {
        let engine = LlamaEngine()
        do {
            try await engine.load(modelAt: #require(Self.modelURL))
            let styler = LlamaStyler(backend: engine, clock: SystemMonotonicClock())
            for raw in [
                "Нужно обязательно добавить защиту на сайты. Там где есть двухфакторная идентификация.",
                "Отправь пожалуйста ссылку в Zoom через Telegram завтра утром.",
                "Please send the report tomorrow morning."
            ] {
                let result = try await styler.style(raw, options: StylingOptions(style: .casual, removeFillers: true, autoPunctuate: true))
                // These fixtures contain letters only; check the word-preservation contract
                // independently of the production validator's numeric/symbol tokenization.
                let words: (String) -> [Substring] = { $0.lowercased().split { !$0.isLetter } }
                #expect(words(result.text) == words(raw))
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }
}
