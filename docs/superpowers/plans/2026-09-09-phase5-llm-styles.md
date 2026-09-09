# VoxFlow v2 Phase 5 — LLM style cleanup on llama.cpp (Qwen2.5 3B), Re-style — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver #112: the Formal / Casual / Very casual tones are rewritten by an on-device LLM (Qwen2.5 3B Instruct, 4-bit GGUF, through llama.cpp), with `RuleStyler` as the fallback whenever the model is absent, still loading, too slow, or produces garbage; "Re-style ▾" on History rows (MW-02s) rewrites a stored dictation into another tone without re-recording and copies the result; the Files result gets its "Apply {Style} cleanup" checkbox (2f).

**Architecture:** A new package module `VoxFlowLLM` wraps the llama.cpp XCFramework in a `LlamaEngine` actor built exactly like `WhisperCppEngine` (one serial queue owns the C pointers; the actor awaits it). `VoxFlowCore` gains the `LLMBackend` / `StyleEngine` protocols so `VoxFlowStyling` never links the binary: `LlamaStyler` (styling module) runs the existing rule pre-pass (fillers, auto-punctuation), then asks the backend to rewrite the text for the chosen tone with a per-tone system prompt, validates the answer, and falls back to `RuleStyler` on any failure. `TextStyler.style` becomes `async throws`. The app adds `StyleModelLoader` (an actor implementing `LLMBackend` over `ModelStore` + `LlamaEngine`: lazy load, warm-up at launch, unload when the model is removed), `DictationStore.updateStyled` for Re-style, and the two UI pieces.

**Tech Stack:** llama.cpp XCFramework `b10881` (binaryTarget `llama`, dynamic framework, Metal), Qwen2.5-3B-Instruct GGUF Q4_K_M via the existing `ModelStore`, Swift 6 strict concurrency, SwiftUI popover, GRDB, Swift Testing.

**Spec:** design spec §2 ("Style LLM: llama.cpp via prebuilt XCFramework, GGUF"), §4 Models, §7 Testing (`RequiresModel`); canvas MW-05 Styles (page 3), MW-02d/MW-02s Re-style menu (PDF page 9), 2f Files result "Apply Casual cleanup" (PDF page 7), ST-03 Models "Cleanup & styles" row (page 6), 3d "Popover / menus" motion. Issue #112. ADR-005 (the seam this phase fills), ADR-002 (engine wrapping pattern). Spike facts: `scratchpad/llama-spike/notes.md` (values copied into the tasks below).

**Rulings (binding):**
1. **Seam change**: `TextStyler.style(_:options:)` becomes `async throws`. `RuleStyler` keeps a synchronous body behind the async signature. `StyledTranscriber` awaits it. No other layer changes (ADR-005 promise).
2. **What the LLM rewrites**: only the tone step. The rule pre-pass (`RuleStyler` with `style: .casual`, honouring `removeFillers` / `autoPunctuate`) runs first and supplies `fillersRemoved`; the LLM receives the pre-passed text. `Verbatim` never touches the LLM. Fallback (`RuleStyler` with the requested tone) whenever: the backend is not ready, the text exceeds **200 words**, generation throws, exceeds **12 s**, or the output fails validation (empty; fewer than 30 % or more than 300 % of the input's words; identical to the prompt; contains `<|im_`).
3. **Determinism**: greedy sampling (`llama_sampler_init_greedy`), `n_ctx 2048`, `n_batch 512`, threads `min(8, activeProcessorCount)`, all layers on Metal (`n_gpu_layers = 99`); `maxNewTokens = min(words × 3 + 32, 768)`. Prompt via the model's own chat template (`llama_model_chat_template` + `llama_chat_apply_template`), never a hand-rolled ChatML string. KV cache cleared before every request (`llama_memory_clear`). One request at a time (actor).
4. **Model lifecycle**: the Qwen row in Settings › Models becomes downloadable by pinning size + sha256 (`ModelsViewModel.Row.isAvailable` already keys on `sha256`). `StyleModelLoader` loads the default `.style` model lazily: `isReady()` returns `true` only when loaded; when a style model is installed but not loaded it kicks one background load and returns `false` (that dictation uses rules). `warmUp()` is called once at launch (non-test) after `dictation.start`, low priority, so the first Metal shader compile (~20 s on first run) never sits on a dictation. Removing the model in Settings unloads it on the next `isReady()` (the store no longer reports it installed). The model stays loaded for the process lifetime (idle unload = follow-up).
5. **Re-style (MW-02s)**: "Re-style ▾" on every readable History row opens a popover anchored to the button with four rows — `Formal`, `Casual`, `Very casual`, `Verbatim` — a `✓` on the record's current style, and the footer `Rewrites locally and copies the result`. Picking a tone rewrites `rawText` through the same `LlamaStyler` (LLM when ready, rules otherwise) with the current global toggles, stores the result (`text`, `words`, `style` updated; `rawText`, `createdAt` untouched), copies the new text to the pasteboard, and refreshes the list. While it runs the button shows a small `ProgressView` in place of the chevron and is disabled; a failure logs and leaves the row unchanged (no canvas copy for an error state). Snippets are **not** re-expanded on Re-style (the stored `rawText` is what the engine heard; the expanded snippet bodies are already in `text` — a Re-style replaces `text` with the rewritten raw transcript).
6. **Files result 2f "Apply {Style} cleanup"**: label = `Apply {defaultStyle.displayName} cleanup` (the canvas shows the default, "Casual"). Default **off** (the auto-export already wrote the raw transcript when the job finished; the canvas sample shows it checked, disclosed). When on, every segment's text goes through `RuleStyler` only (fillers/auto-punctuate per the global toggles + the tone rules) — the LLM is **not** used for files (a 1.5-hour lecture has thousands of segments; "instant, no re-processing" is what 2f promises). The preview, Copy, Save as… and "Also export" all use the cleaned document while the box is checked. LLM cleanup for short file transcripts = follow-up issue.
7. **Styles page** (MW-05) keeps its fixed sample strings (4a ruling 8) — the canvas shows fixed samples, not live output.
8. **Integration test** tagged `.requiresModel` (Swift Testing `Tag`) in `VoxFlowLLMTests` runs only when `~/Library/Application Support/VoxFlow/Models/qwen2.5-3b-instruct-q4_k_m.gguf` exists (or `VOXFLOW_STYLE_MODEL` points at a GGUF); otherwise it records a `.skip`-style early return with a printed reason (Swift Testing has no runtime skip — the test prints `"skipped: style model not installed"` and returns; disabled-on-CI by absence).
9. **Package layout**: `LLMBackend`, `StyleEngine`, `ChatPrompt`, `LLMError` live in `VoxFlowCore`; `LlamaStyler`, `StylePrompts`, `StyleLimits`, `OutputValidator` in `VoxFlowStyling` (depends on Core only); `LlamaEngine`, `LlamaParameters` in the new `VoxFlowLLM` (depends on Core + `llama`). `FakeLLMBackend` / `FakeStyleEngine` in `VoxFlowTestSupport`. `@unchecked Sendable` is allowed **only** for the two pointer/flag boxes inside `VoxFlowLLM`, each with the same "touched only on `queue`" comment `WhisperCppEngine` carries; nowhere else.
10. **Prompts** (exact, `StylePrompts.system(for:)`), each ending with the same two sentences:
    - Formal: `You clean up dictated speech. Rewrite the user's text as clear, polite, professional language suitable for a work email: complete sentences, no contractions, correct punctuation and capitalization.`
    - Casual: `You clean up dictated speech. Rewrite the user's text as natural, friendly everyday language, the way a person types a quick message to a colleague: light punctuation, contractions are fine, fix grammar and remove hesitations.`
    - Very casual: `You clean up dictated speech. Rewrite the user's text as a short, relaxed chat message: lowercase is fine, minimal punctuation, contractions, brief and informal.`
    - Common tail (appended after one space): `Keep every fact, name, number and the original meaning, and write in the same language as the user's text. Do not add greetings, sign-offs, emoji, explanations or quotes. Reply with the rewritten text only.`
    - The user message is the pre-passed text, verbatim.

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated` outside the two documented boxes in `VoxFlowLLM` (ruling 9).
- Views hold no rules; every number/string decision in a tested type. Copy verbatim from the canvas (quoted per task). Design reference `.superpowers/design/canvas.pdf`; render tests (`VOXFLOW_RENDER=1`) per UI task; implementer + reviewer compare.
- Blocking storage and all llama.cpp calls off the main actor; no sleeps in non-render tests (`FakeClock` for timeouts).
- No network except the user-initiated model download through `ModelStore`; nothing is sent anywhere by the styler.
- Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/112-v2-style-llm` from `develop`; PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test` where the package changed; `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`.

---

### Task 1: `VoxFlowLLM` — llama.cpp binary target, `LlamaEngine`, Core protocols, catalog pins

**Files:**
- Modify: `VoxFlowKit/Package.swift` — add `.binaryTarget(name: "llama", url: "https://github.com/ggml-org/llama.cpp/releases/download/b10881/llama-b10881-xcframework.zip", checksum: "7a86995c5f2127f897c0eeec78e0f32fec8fac750027ea1707885fbc5dbcebcd")`, `.target(name: "VoxFlowLLM", dependencies: ["VoxFlowCore", "llama"])`, product `VoxFlowLLM`, `.testTarget(name: "VoxFlowLLMTests", dependencies: ["VoxFlowLLM", "VoxFlowTestSupport"])`.
- Create: `VoxFlowKit/Sources/VoxFlowCore/LLM.swift`:

```swift
import Foundation

/// One chat turn for a style rewrite: a system instruction plus the user's text.
public struct ChatPrompt: Sendable, Equatable {
    public var system: String
    public var user: String
    public init(system: String, user: String) { self.system = system; self.user = user }
}

public enum LLMError: Error, Equatable, Sendable {
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
```

- Create: `VoxFlowKit/Sources/VoxFlowLLM/LlamaParameters.swift`:

```swift
import Foundation

/// The numbers the engine hands to llama.cpp (plan ruling 3) — pure so tests can pin them.
public struct LlamaParameters: Sendable, Equatable {
    public var contextTokens: Int32 = 2048
    public var batchTokens: Int32 = 512
    public var threadCount: Int32
    public var gpuLayers: Int32 = 99

    public init(availableCores: Int) {
        threadCount = Int32(max(1, min(8, availableCores)))
    }
}
```

- Create: `VoxFlowKit/Sources/VoxFlowLLM/LlamaEngine.swift` — mirror `WhisperCppEngine` (read it first: `VoxFlowKit/Sources/VoxFlowSpeech/WhisperCppEngine.swift`):

```swift
import Foundation
import VoxFlowCore
import llama

/// `StyleEngine` over llama.cpp. Every C call happens on `queue`; the actor serializes requests and
/// awaits the queue, so a multi-second generation never blocks a cooperative thread.
public actor LlamaEngine: StyleEngine {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.llama", qos: .userInitiated)
    private let parameters: LlamaParameters
    private var model: ModelBox?
    private var context: ContextBox?
    private static let backendInit: Void = { llama_backend_init() }()

    public init(parameters: LlamaParameters = LlamaParameters(availableCores: ProcessInfo.processInfo.activeProcessorCount)) {
        self.parameters = parameters
    }

    /// Owns the `llama_model` pointer and frees it when the engine (or an in-flight run) lets go.
    final class ModelBox: @unchecked Sendable {
        // Safe: the pointer is only dereferenced on LlamaEngine.queue while runs are in flight;
        // deinit runs when the last reference goes away, so nothing can be using it.
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { llama_model_free(pointer) }
    }

    final class ContextBox: @unchecked Sendable {
        // Safe: same rule as ModelBox — only touched on LlamaEngine.queue.
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { llama_free(pointer) }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    public func isReady() async -> Bool { context != nil }

    public func load(modelAt url: URL) async throws {
        _ = Self.backendInit
        let path = url.path
        let parameters = parameters
        let boxes: (ModelBox, ContextBox) = try await onQueue {
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = parameters.gpuLayers
            guard let model = llama_model_load_from_file(path, modelParams) else { throw LLMError.modelLoadFailed(path) }
            let modelBox = ModelBox(model)
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = UInt32(parameters.contextTokens)
            contextParams.n_batch = UInt32(parameters.batchTokens)
            contextParams.n_threads = parameters.threadCount
            contextParams.n_threads_batch = parameters.threadCount
            guard let context = llama_init_from_model(model, contextParams) else { throw LLMError.modelLoadFailed(path) }
            return (modelBox, ContextBox(context))
        }
        context = nil
        model = boxes.0
        context = boxes.1
    }

    public func unload() async {
        context = nil
        model = nil
    }

    public func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard let model, let context else { throw LLMError.modelNotLoaded }
        let limit = Int(parameters.contextTokens)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await onQueue {
                let vocab = llama_model_get_vocab(model.pointer)
                let text = try Self.applyTemplate(model: model.pointer, prompt: prompt)
                var tokens = try Self.tokenize(vocab: vocab, text: text)
                guard tokens.count + maxNewTokens <= limit else { throw LLMError.promptTooLong(tokens: tokens.count, limit: limit) }

                llama_memory_clear(llama_get_memory(context.pointer), true)
                var batch = llama_batch_init(Int32(self.parameters.batchTokens), 0, 1)
                defer { llama_batch_free(batch) }

                // Prompt evaluation in n_batch-sized chunks; logits only for the last prompt token.
                var position: Int32 = 0
                var offset = 0
                while offset < tokens.count {
                    let count = min(tokens.count - offset, Int(self.parameters.batchTokens))
                    batch.n_tokens = Int32(count)
                    for i in 0..<count {
                        batch.token[i] = tokens[offset + i]
                        batch.pos[i] = position + Int32(i)
                        batch.n_seq_id[i] = 1
                        batch.seq_id[i]![0] = 0
                        batch.logits[i] = (offset + i == tokens.count - 1) ? 1 : 0
                    }
                    let code = llama_decode(context.pointer, batch)
                    guard code == 0 else { throw LLMError.decodeFailed(code: code) }
                    position += Int32(count)
                    offset += count
                    if cancel.isSet { throw LLMError.cancelled }
                }

                let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
                defer { llama_sampler_free(sampler) }
                llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

                var output: [UInt8] = []
                var piece = [CChar](repeating: 0, count: 256)
                for _ in 0..<maxNewTokens {
                    let token = llama_sampler_sample(sampler, context.pointer, -1)
                    llama_sampler_accept(sampler, token)
                    if llama_vocab_is_eog(vocab, token) { break }
                    let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
                    if length < 0 {
                        piece = [CChar](repeating: 0, count: Int(-length) + 1)
                        _ = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
                        output.append(contentsOf: piece.prefix(Int(-length)).map { UInt8(bitPattern: $0) })
                    } else {
                        output.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
                    }
                    batch.n_tokens = 1
                    batch.token[0] = token
                    batch.pos[0] = position
                    batch.n_seq_id[0] = 1
                    batch.seq_id[0]![0] = 0
                    batch.logits[0] = 1
                    position += 1
                    tokens.append(token)
                    let code = llama_decode(context.pointer, batch)
                    guard code == 0 else { throw LLMError.decodeFailed(code: code) }
                    if cancel.isSet { throw LLMError.cancelled }
                }
                return String(decoding: output, as: UTF8.self)
            }
        } onCancel: {
            cancel.set()
        }
    }

    private static func applyTemplate(model: OpaquePointer, prompt: ChatPrompt) throws -> String {
        let template = llama_model_chat_template(model, nil)   // nil → the GGUF's own tokenizer.chat_template (Qwen: ChatML)
        let system = strdup(prompt.system), user = strdup(prompt.user)
        let roleSystem = strdup("system"), roleUser = strdup("user")
        defer { free(system); free(user); free(roleSystem); free(roleUser) }
        var messages = [llama_chat_message(role: roleSystem, content: system), llama_chat_message(role: roleUser, content: user)]
        var buffer = [CChar](repeating: 0, count: prompt.system.utf8.count + prompt.user.utf8.count + 256)
        var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        if length > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        guard length > 0 else { throw LLMError.tokenizationFailed }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokenize(vocab: OpaquePointer?, text: String) throws -> [llama_token] {
        let bytes = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: bytes.count + 16)
        let count = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                llama_tokenize(vocab, chars.baseAddress, Int32(bytes.count), &tokens, Int32(tokens.count), true, true)
            }
        }
        guard count > 0 else { throw LLMError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
```

  If a signature above does not compile against the b10881 headers (e.g. `llama_chat_message` field names, `batch.seq_id[i]!` optionality, `llama_sampler_chain_default_params`), read `llama.h` in the checked-out artifact (`VoxFlowKit/.build/artifacts/voxflowkit/llama/llama.xcframework/macos-arm64_x86_64/llama.framework/Headers/llama.h`) and adapt — the intent (greedy single-sequence decode, cancel checked per token, template from the GGUF) is binding; the exact Swift spelling is not. Never use the deprecated names `llama_load_model_from_file`, `llama_new_context_with_model`, `llama_token_is_eog`, `llama_kv_self_clear`.

- Modify: `VoxFlowKit/Sources/VoxFlowModels/ModelCatalog.swift` — the Qwen entry: `sizeInBytes: 2_104_932_768`, `sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d"`, remove the TODO comment. Keep `languagesSummary` and `isDefault: true`.
- Create: `VoxFlowKit/Sources/VoxFlowTestSupport/FakeLLMBackend.swift`:

```swift
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

    public init(ready: Bool = true, reply: String = "") { self.ready = ready; self.reply = reply }

    public func set(ready: Bool) { self.ready = ready }
    public func set(reply: String) { self.reply = reply }
    public func set(error: LLMError?) { self.error = error }
    public func set(hangs: Bool) { self.hangs = hangs }
    public func release() { waiters.forEach { $0.resume() }; waiters.removeAll() }

    public func isReady() async -> Bool { ready }

    public func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        prompts.append(prompt); maxTokens.append(maxNewTokens)
        if let error { throw error }
        if hangs {
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
```

- Create: `VoxFlowKit/Tests/VoxFlowLLMTests/LlamaParametersTests.swift` (threads clamp `1…8`, defaults 2048/512/99) and `VoxFlowKit/Tests/VoxFlowLLMTests/LlamaEngineIntegrationTests.swift`:

```swift
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

    @Test("rewrites a fixture differently per tone (real model)")
    func rewritesPerTone() async throws {
        guard let url = Self.modelURL else { print("skipped: style model not installed"); return }
        let engine = LlamaEngine()
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
        await engine.unload()
        #expect(!(await engine.isReady()))
    }

    @Test("generate without a model throws modelNotLoaded")
    func notLoaded() async {
        let engine = LlamaEngine()
        await #expect(throws: LLMError.modelNotLoaded) { try await engine.generate(ChatPrompt(system: "a", user: "b"), maxNewTokens: 8) }
    }
}
```

- Modify: `VoxFlowKit/Tests/VoxFlowModelsTests/ModelCatalogTests.swift` (or the test that covers the catalog) — assert the Qwen entry's `sizeInBytes == 2_104_932_768`, `sha256.count == 64`, `role == .style`, `fileName == "qwen2.5-3b-instruct-q4_k_m.gguf"`.
- Modify: `scripts/affected_tests.py` mapping if it lists modules explicitly (add `VoxFlowLLM` → `VoxFlowLLMTests`; run `python3 -m unittest discover -s scripts/tests`).

**Interfaces:**
- Produces: `LLMBackend`, `StyleEngine`, `ChatPrompt`, `LLMError` (Core); `LlamaEngine`, `LlamaParameters` (LLM); `FakeLLMBackend` (TestSupport); pinned catalog entry.

- [ ] Write `LlamaParametersTests` + the catalog assertions; run → RED; implement Core protocols, catalog pins, `LlamaParameters` → GREEN.
- [ ] Add the binary target + `VoxFlowLLM` + `LlamaEngine`; `swift build` must succeed under strict concurrency with zero warnings; run the integration test (it prints "skipped" without the model — if the owner's model exists at the default path, it runs for real; report the outcome either way).
- [ ] `xcodegen generate && xcodebuild … build test` (the app links `VoxFlowLLM` only in Task 3, but the package products must resolve).
- [ ] Commit: `feat(llm): llama.cpp XCFramework, LlamaEngine and the LLMBackend seam; pin the Qwen2.5 3B catalog entry`

### Task 2: `LlamaStyler` — async `TextStyler`, prompts, limits, validation, fallback

**Files:**
- Modify: `VoxFlowKit/Sources/VoxFlowCore/Styling.swift` — `func style(_ raw: String, options: StylingOptions) async throws -> StyledText`.
- Modify: `VoxFlowKit/Sources/VoxFlowStyling/RuleStyler.swift` — conform to the async signature; keep the body synchronous; add `public func styleSync(_ raw: String, options: StylingOptions) -> StyledText` (the old body) and make `style` call it.
- Create: `VoxFlowKit/Sources/VoxFlowStyling/StylePrompts.swift`:

```swift
import VoxFlowCore

/// The system prompts (plan ruling 10) — exact strings, one per rewriting tone. `verbatim` has none.
public enum StylePrompts {
    static let tail = "Keep every fact, name, number and the original meaning, and write in the same language as the user's text. Do not add greetings, sign-offs, emoji, explanations or quotes. Reply with the rewritten text only."

    public static func system(for style: TextStyle) -> String? {
        switch style {
        case .formal:
            "You clean up dictated speech. Rewrite the user's text as clear, polite, professional language suitable for a work email: complete sentences, no contractions, correct punctuation and capitalization. " + tail
        case .casual:
            "You clean up dictated speech. Rewrite the user's text as natural, friendly everyday language, the way a person types a quick message to a colleague: light punctuation, contractions are fine, fix grammar and remove hesitations. " + tail
        case .veryCasual:
            "You clean up dictated speech. Rewrite the user's text as a short, relaxed chat message: lowercase is fine, minimal punctuation, contractions, brief and informal. " + tail
        case .verbatim:
            nil
        }
    }

    public static func prompt(for style: TextStyle, text: String) -> ChatPrompt? {
        system(for: style).map { ChatPrompt(system: $0, user: text) }
    }
}
```

- Create: `VoxFlowKit/Sources/VoxFlowStyling/StyleLimits.swift`:

```swift
import Foundation

/// Ruling 2/3: when the LLM is used at all, and how much it may generate.
public struct StyleLimits: Sendable, Equatable {
    public var maxInputWords = 200
    public var generationTimeout: TimeInterval = 12
    public var maxNewTokensCap = 768
    public init() {}

    public func maxNewTokens(forWords words: Int) -> Int { min(words * 3 + 32, maxNewTokensCap) }
    public func allowsLLM(words: Int) -> Bool { words > 0 && words <= maxInputWords }
}

/// Ruling 2: what counts as a usable LLM answer.
public enum OutputValidator {
    public static func clean(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func isAcceptable(_ output: String, input: String) -> Bool {
        let outWords = output.wordCount, inWords = max(1, input.wordCount)
        guard outWords > 0, !output.contains("<|im_") else { return false }
        guard output != input else { return false }
        return Double(outWords) >= 0.3 * Double(inWords) && Double(outWords) <= 3.0 * Double(inWords)
    }
}
```

  (`String.wordCount` exists in `VoxFlowCore` — reuse it.)

- Create: `VoxFlowKit/Sources/VoxFlowStyling/LlamaStyler.swift`:

```swift
import Foundation
import VoxFlowCore

/// LLM-backed `TextStyler` (ADR-007): rule pre-pass → LLM tone rewrite → validation, falling back to
/// `RuleStyler` with the requested tone on every failure path. Never throws — a styling failure must
/// never lose a dictation.
public struct LlamaStyler: TextStyler, Sendable {
    public let backend: any LLMBackend
    public let rules: RuleStyler
    public let limits: StyleLimits
    public let clock: any MonotonicClock

    public init(backend: any LLMBackend, rules: RuleStyler = RuleStyler(), limits: StyleLimits = StyleLimits(), clock: any MonotonicClock) {
        self.backend = backend; self.rules = rules; self.limits = limits; self.clock = clock
    }

    public func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
        let fallback = rules.styleSync(raw, options: options)
        guard options.style != .verbatim, let prompt = StylePrompts.prompt(for: options.style, text: "") else { return fallback }
        let prepass = rules.styleSync(raw, options: StylingOptions(style: .casual, removeFillers: options.removeFillers, autoPunctuate: options.autoPunctuate))
        let words = prepass.text.wordCount
        guard limits.allowsLLM(words: words), await backend.isReady() else { return fallback }

        let request = ChatPrompt(system: prompt.system, user: prepass.text)
        let maxNewTokens = limits.maxNewTokens(forWords: words)
        let backend = backend, clock = clock, timeout = limits.generationTimeout
        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await backend.generate(request, maxNewTokens: maxNewTokens) }
            group.addTask { try? await clock.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output else { return fallback }
        let cleaned = OutputValidator.clean(output)
        guard OutputValidator.isAcceptable(cleaned, input: prepass.text) else { return fallback }
        return StyledText(text: cleaned, fillersRemoved: prepass.fillersRemoved, cursorOffset: nil)
    }
}
```

  Note the timeout race: the first task to finish wins; `cancelAll()` cancels the other (the engine sees the cancel flag per token; `FakeClock.sleep` honours cancellation).

- Modify: `VoxFlow/Styling/StyledTranscriber.swift` — `let styled = try await styler.style(result.rawText, options: stylingOptions)`; on throw, fall back to `RuleStyler().styleSync` (never lose the dictation).
- Modify: `VoxFlowKit/Tests/VoxFlowStylingTests/RuleStylerTests.swift` and any test calling `style(` — `await`/`try` as needed; existing assertions unchanged.
- Create: `VoxFlowKit/Tests/VoxFlowStylingTests/LlamaStylerTests.swift` — with `FakeLLMBackend` + `FakeClock`:
  1. `formalPromptIsExact`: reply `"Could we move the meeting to Thursday afternoon? I need the numbers from Finance first."`; assert `prompts.first?.system == StylePrompts.system(for: .formal)`, the user text is the pre-passed text (fillers stripped: raw `"um can we push the meeting to thursday"` → user `"Can we push the meeting to thursday."` given `autoPunctuate: true`), result text == reply, `fillersRemoved == 1`.
  2. `verbatimSkipsBackend`: `.verbatim` → no prompts recorded, text == raw.
  3. `notReadyFallsBackToRules`: `ready: false` → no prompts; result == `RuleStyler().styleSync(raw, options)`.
  4. `overCapFallsBackToRules`: 201-word input → no prompts.
  5. `emptyReplyFallsBack`, `garbageReplyFallsBack` (`"<|im_start|>assistant"`), `tooShortReplyFallsBack` (1 word for a 20-word input), `quotesAreStripped` (`"\"hello there\""` → `hello there`).
  6. `timeoutFallsBack`: `hangs = true`; start `style` in a `Task`; `await clock.waitForSleepers(1)`; `await clock.advance(by: 12)`; result == rule fallback; the backend received the prompt.
  7. `errorFallsBack`: `error = .decodeFailed(code: 1)` → rule fallback.
  8. `maxNewTokensFollowsWords`: 10-word input → `maxTokens.first == 62`; 300-word cap check via `StyleLimits` directly (`maxNewTokens(forWords: 300) == 768`).
  9. `StylePromptsTests`: every non-verbatim prompt ends with the common tail; `verbatim` → nil.
  10. `OutputValidatorTests`: the ratio bounds at exactly 30 % and 300 %.
- Modify: `VoxFlowTests/StyledTranscriberTests.swift` (if present) for the `await`.

**Interfaces:**
- Consumes: `LLMBackend`, `ChatPrompt`, `FakeLLMBackend`, `FakeClock` (Task 1 / TestSupport).
- Produces: `LlamaStyler(backend:rules:limits:clock:)`, `StylePrompts`, `StyleLimits`, `OutputValidator`, `RuleStyler.styleSync`.

- [ ] Tests → RED → implementation → GREEN (package `swift test`, then the app build+test for the `StyledTranscriber` change).
- [ ] Commit: `feat(styling): async TextStyler and LlamaStyler with prompts, limits and rule fallback`

### Task 3: App wiring — `StyleModelLoader`, composition root, Re-style storage path

**Files:**
- Create: `VoxFlow/Styling/StyleModelLoader.swift`:

```swift
import Foundation
import OSLog
import VoxFlowCore
import VoxFlowModels

/// Lazy owner of the style model (plan ruling 4). Implements `LLMBackend` for `LlamaStyler`: ready
/// only when the default `.style` model from `ModelStore` is loaded into `engine`; an installed but
/// unloaded model starts one background load and reports not-ready; a removed model is unloaded.
actor StyleModelLoader: LLMBackend {
    private let store: ModelStore
    private let engine: any StyleEngine
    private(set) var loadedModelID: String?
    private var loadTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "style-model")

    init(store: ModelStore, engine: any StyleEngine) { self.store = store; self.engine = engine }

    func isReady() async -> Bool {
        guard let model = await store.defaultModel(role: .style) else {
            if loadedModelID != nil { await unload() }
            return false
        }
        if loadedModelID == model.id { return true }
        if loadTask == nil { loadTask = Task { await self.load(model) } }
        return false
    }

    /// Launch hook: same as `isReady()` but awaited, so the first dictation after launch can already
    /// use the LLM once the Metal shaders and weights are in memory.
    func warmUp() async {
        guard let model = await store.defaultModel(role: .style), loadedModelID != model.id else { return }
        if loadTask == nil { loadTask = Task { await self.load(model) } }
        await loadTask?.value
    }

    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard loadedModelID != nil else { throw LLMError.modelNotLoaded }
        return try await engine.generate(prompt, maxNewTokens: maxNewTokens)
    }

    private func load(_ model: ModelDescriptor) async {
        defer { loadTask = nil }
        do {
            try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName))
            loadedModelID = model.id
        } catch {
            Self.log.error("style model load failed: \(String(describing: error))")
            loadedModelID = nil
        }
    }

    private func unload() async {
        await engine.unload()
        loadedModelID = nil
    }
}
```

- Modify: `VoxFlow/App/AppServices.swift` — build `let styleEngine = LlamaEngine()`, `let styleModelLoader = StyleModelLoader(store: modelStore, engine: styleEngine)`, `let styler = LlamaStyler(backend: styleModelLoader, clock: clock)` (the shared `SystemMonotonicClock` instance), pass `styler` to `StyledTranscriber`; expose `styleModelLoader` and a `restyler: Restyler` (below). `project.yml`: add `VoxFlowLLM` to the app's package products (mirror how `VoxFlowSpeech` is listed).
- Modify: `VoxFlow/App/AppDelegate.swift` — after `dictation.start()` (non-test only): `Task(priority: .utility) { await services.styleModelLoader.warmUp() }`.
- Create: `VoxFlow/Styling/Restyler.swift`:

```swift
import Foundation
import VoxFlowCore

/// Re-style (MW-02s): rewrite a stored raw transcript into another tone with the current global
/// toggles, through whatever styler the app runs (LLM when ready, rules otherwise).
struct Restyler: Sendable {
    let styler: any TextStyler
    let settings: StylingSettingsBox

    func restyle(rawText: String, to style: TextStyle) async -> String {
        let snapshot = settings.current
        let options = StylingOptions(style: style, removeFillers: snapshot.removeFillers, autoPunctuate: snapshot.autoPunctuate)
        return (try? await styler.style(rawText, options: options))?.text ?? RuleStyler().styleSync(rawText, options: options).text
    }
}
```

  (import `VoxFlowStyling` for `RuleStyler`.)

- Modify: `VoxFlowKit/Sources/VoxFlowStorage/DictationStore.swift`:

```swift
/// Re-style: replaces the inserted text and its style, recomputing `words`; `raw_text` and
/// `created_at` are untouched. Returns nil when the row no longer exists.
public func updateStyled(id: Int64, text: String, style: String) throws -> DictationRecord? {
    let words = DictationRecord.wordCount(text)
    let encoded = try encode(text)
    let changed = try queue.write { db in
        try db.execute(sql: "UPDATE dictations SET text = ?, style = ?, words = ?, encrypted = ? WHERE id = ?",
                       arguments: [encoded, style, words, cipher != nil, id])
        return db.changesCount
    }
    guard changed > 0 else { return nil }
    return try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM dictations WHERE id = ?", arguments: [id]) }.map(record(from:))
}
```

  Tests: `DictationStoreTests` — update on an encrypted store round-trips through `fetch` (new text, new style, new word count, same `rawText`/`createdAt`), unknown id → nil, an unreadable row (key lost) is not touched by other rows' updates.
- Modify: `VoxFlow/Dictation/HistoryService.swift` — `func updateStyled(id: Int64, text: String, style: String) async -> DictationRecord?` (same `ensureOpened`/detached pattern as `delete`; `notifyChanged()` on success). Test in `HistoryServiceTests`.
- Modify: `VoxFlow/Settings/ModelsViewModel.swift` — nothing functional (the row's `isAvailable` flips via the catalog); verify `ModelsViewModelTests` cover a `.style` row that is downloadable now, and that removing the style model shows the alert without the "dictation keeps working" clause (existing behaviour) — add the assertion if missing.
- Create: `VoxFlowTests/StyleModelLoaderTests.swift` — temp `ModelStore` (see `ModelsViewModelTests` for the fixture pattern: a temp directory, `FakeModelDownloader`, `FakeFreeSpace`, `InMemoryKeyValueStore`) + `FakeLLMBackend` as the engine:
  1. no style model on disk → `isReady() == false`, engine untouched;
  2. model file present (write a fake file with the catalog file name; `ModelStore.state(of:)` must report installed — check how `ModelStore` decides "installed" (file exists + size?) and satisfy it, e.g. by writing exactly `sizeInBytes` bytes if it checks size, else any bytes) → first `isReady()` false and a load starts; `await loader.warmUp()`; second `isReady()` true; `loadedURLs.last?.lastPathComponent == "qwen2.5-3b-instruct-q4_k_m.gguf"`;
  3. delete the file → `isReady()` false and `unloadCount == 1`;
  4. `generate` before load throws `modelNotLoaded`; after load forwards the prompt.
- Create: `VoxFlowTests/RestylerTests.swift` — with `FakeLLMBackend`: LLM reply used when ready; rules when not ready; the toggles from the box are applied (`removeFillers` false keeps "um").

**Interfaces:**
- Consumes: `LlamaEngine`, `LlamaStyler`, `StyleEngine`, `FakeLLMBackend` (Tasks 1–2).
- Produces: `StyleModelLoader` (`isReady`, `warmUp`, `generate`), `Restyler.restyle(rawText:to:)`, `DictationStore.updateStyled`, `HistoryService.updateStyled`, `AppServices.restyler` / `.styleModelLoader`.

- [ ] Tests → RED → implementation → GREEN (package + app).
- [ ] Commit: `feat(app): lazy style model loader, LlamaStyler in the dictation path, Re-style storage`

### Task 4: Re-style menu (MW-02s) in History

**Design (PDF page 9, "2e" detail with the menu open):** the expanded row's action strip keeps `Copy · Re-style ▾ · Delete`. Clicking "Re-style ▾" opens a small popover under the button: four rows `Formal`, `Casual`, `Very casual`, `Verbatim`, each 26 pt tall, with a `✓` in a 14 pt leading slot on the record's current style; a hairline divider; footer `Rewrites locally and copies the result` (11 pt, secondary). Motion (3d "Popover / menus"): 120 ms fade + 4 pt rise; dismiss on outside click or Esc. While a Re-style runs: the button's chevron becomes a 12 pt `ProgressView` and the strip's buttons are disabled.

**Files:**
- Modify: `VoxFlow/History/HistoryViewModel.swift`:

```swift
private(set) var restylingID: Int64?
let restyler: Restyler            // injected (init parameter), FakeLLMBackend-backed in tests

func restyle(_ record: DictationRecord, to style: TextStyle) async {
    guard restylingID == nil, !record.isUnreadable else { return }
    restylingID = record.id
    defer { restylingID = nil }
    let text = await restyler.restyle(rawText: record.rawText, to: style)
    guard let updated = await service.updateStyled(id: record.id, text: text, style: style.rawValue) else { return }
    pasteboard.setString(updated.text)
    await refresh()
}

static func currentStyle(of record: DictationRecord) -> TextStyle { record.style.flatMap(TextStyle.init(rawValue:)) ?? .casual }
static let restyleFooter = "Rewrites locally and copies the result"
static let restyleOrder: [TextStyle] = [.formal, .casual, .veryCasual, .verbatim]
```

- Create: `VoxFlow/History/RestyleMenuView.swift` — the popover body (rows from `HistoryViewModel.restyleOrder`, `✓` when `== currentStyle`, footer), calls `Task { await model.restyle(record, to: style) }` and dismisses.
- Modify: `VoxFlow/History/HistoryRowView.swift` — enable the button (`.foregroundStyle(.tint)`), `@State private var isRestyleShown = false`, `.popover(isPresented:arrowEdge: .bottom) { RestyleMenuView(...) }`, the spinner variant while `model.restylingID == record.id`, `.disabled(model.restylingID != nil)` on the strip.
- Modify: `VoxFlow/App/AppServices.swift` — pass `restyler` into `HistoryViewModel`.
- Tests: `HistoryViewModelTests` — `restyleUpdatesRowAndCopies` (store seeded with one record, `FakeLLMBackend(reply: "Could we move it?")`; after `restyle(_, to: .formal)`: fetched row text == reply, `style == "formal"`, pasteboard == reply, `restylingID == nil`); `restyleFallsBackToRulesWhenNotReady`; `restyleIgnoresUnreadableRows`; `restyleIsSingleFlight` (a hanging backend: second call returns immediately, then `release()`); `currentStyle` default `.casual` for nil/unknown. `HistoryRenderTests` — `VOXFLOW_RENDER=1` renders `RestyleMenuView` for a record with `veryCasual` → `.superpowers/design/renders/History-restyle-menu.png`; compare with page 9.

**Interfaces:**
- Consumes: `Restyler`, `HistoryService.updateStyled` (Task 3).

- [ ] Tests → RED → implementation → GREEN; render + compare; commit: `feat(app): Re-style menu on History rows (MW-02s)`

### Task 5: Files 2f "Apply {Style} cleanup", ADR-007, docs, owner checklist

**Design (PDF page 7, 2f):** in the toolbar row under the header, right of "Segment length ▾ Sentences" (not built — leave the existing comment, it is not in #112), a checkbox `☑ Apply Casual cleanup`. Ruling 6: label uses the default style's display name; default off; rule-based per segment.

**Files:**
- Modify: `VoxFlow/Files/ResultViewModel.swift` — `init` gains `cleanupStyle: TextStyle, cleanupOptions: StylingOptions` (built by `FilesPage` from `StylingSettings.snapshot`: style = `defaultStyle`, toggles from the snapshot); `var applyCleanup = false { didSet { rerender() } }`; `var cleanupLabel: String { "Apply \(cleanupStyle.displayName) cleanup" }`; `private(set) lazy var cleanedDocument: TranscriptDocument` = the document with every segment's text replaced by `RuleStyler().styleSync(text, options: cleanupOptions).text` (computed once, on first use, off the main actor is not required — `RuleStyler` on 14 k words is milliseconds; measure in the test: < 1 s for 5 000 segments); `var activeDocument: TranscriptDocument { applyCleanup ? cleanedDocument : document }`; `rerender()`, `copy()`, `exportAlso`, `visibleIndexedSegments` and the "Save as…" contents all read `activeDocument`.
- Modify: `VoxFlow/Files/TranscriptResultView.swift` — `Toggle(resultModel.cleanupLabel, isOn: $resultModel.applyCleanup).toggleStyle(.checkbox)` in the search/controls row, trailing; replace the "phase 4/5" comment with one that says segment length is a follow-up.
- Modify: `VoxFlow/Files/FilesPage.swift` — pass `cleanupStyle`/`cleanupOptions` from `services.stylingSettings`.
- Tests: `ResultViewModelTests` — `cleanupLabelUsesDefaultStyle` (`.veryCasual` → `"Apply Very casual cleanup"`), `cleanupOffKeepsRawSegments`, `cleanupOnRewritesEverySegmentAndExports` (a segment `"um so we start"` with `removeFillers: true` → `"So we start."`; `rendered` and `exportAlso` use it; toggling back off restores), `cleanupIsFast` (5 000 short segments, `< 1 s`, measured with `ContinuousClock`).
- Create: `docs/adr/007-llm-styling-on-llama-cpp.md` — Context (ADR-005's seam; canvas MW-05/MW-02s/2f), Decision (rulings 1–6, 9, 10 in prose: async seam, rule pre-pass + LLM tone rewrite, fallback matrix, determinism parameters, lazy lifecycle + warm-up, Re-style semantics, Files rules-only), Consequences (2.1 GB download and ~2.5 GB resident memory while loaded; llama.cpp tracks build tags not semver → re-pin per `docs/runbooks/dependency-updates.md`; first-run Metal shader compile; both engines share the GPU — see #145; Re-style replaces expanded snippets). Add the row to `docs/adr/README.md`.
- Modify: `README.md` (feature list: on-device style cleanup, Re-style), `CHANGELOG.md` (Unreleased: phase 5 items), `SETUP.md` ("Style model" paragraph: download from Settings › Models, 2.1 GB, where it lives, `VOXFLOW_STYLE_MODEL` for the integration test, rules fallback when absent).
- Owner checklist (append to this plan under "Manual checklist (owner)"): download Qwen in Settings › Models (progress, checksum, "Installed"); dictate the same sentence with Formal / Casual / Very casual (Styles page) — visibly different, style-appropriate; remove the model → dictation still works (rule-based); History → Re-style ▾ → pick a tone → row updates and the clipboard has the new text; Files → open a result → check "Apply Casual cleanup" → segments change, Save as… writes the cleaned text; first launch after install: no beachball while the model warms up.

**Interfaces:**
- Consumes: `RuleStyler.styleSync`, `StylingSettings.snapshot` (Task 2, existing).

- [ ] Tests → RED → implementation → GREEN; render the result view (`VOXFLOW_RENDER=1`, `FilesRenderTests` if present, else add one for `TranscriptResultView` with the checkbox on) and compare with page 7.
- [ ] Commit: `feat(app): "Apply {Style} cleanup" on the Files result (2f)`; `docs: ADR-007 LLM styling; README/CHANGELOG/SETUP; phase 5 checklist`

---

## Manual checklist (owner)

Filled in by Task 5 (see above) — run after the PR merges into `develop`.

## Self-review

- **Spec coverage:** #112 criteria — `LlamaStyler` unit tests with a fake backend per preset + fallback (Task 2); `RequiresModel` integration test (Task 1); `swift test` for `VoxFlowStyling` (Tasks 1–2); visibly different tones in the running app (Task 3 wiring + owner checklist); Re-style on a History item (Tasks 3–4); CI green (PR). Canvas: MW-02s (Task 4), 2f checkbox (Task 5), ST-03 Qwen row (Task 1 pins). Spec §4 "one ModelStore, one download/verify path" — no new download code.
- **Placeholders:** none; every prompt, number and filename is literal.
- **Type consistency:** `TextStyler.style` async throws (Task 2) used by `StyledTranscriber` (2), `Restyler` (3), `LlamaStyler` (2); `StyleEngine` (1) implemented by `LlamaEngine` (1) and `FakeLLMBackend` (1), consumed by `StyleModelLoader` (3); `DictationStore.updateStyled` (3) → `HistoryService.updateStyled` (3) → `HistoryViewModel.restyle` (4); `RuleStyler.styleSync` (2) used by `LlamaStyler` (2), `Restyler` (3), `ResultViewModel` (5).
