import Foundation
import VoxFlowCore
import llama

/// `StyleEngine` over llama.cpp. Every C call happens on `queue`; the actor serializes requests and
/// awaits the queue, so a multi-second generation never blocks a cooperative thread.
public actor LlamaEngine: StyleEngine {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.llama", qos: .userInitiated)
    private let parameters: LlamaParameters
    private var context: ContextBox?
    private static let backendInit: Void = { llama_backend_init() }()

    public init(parameters: LlamaParameters = LlamaParameters(availableCores: ProcessInfo.processInfo.activeProcessorCount)) {
        self.parameters = parameters
    }

    /// Owns the `llama_model` pointer. Whoever drops the last reference (the actor, or an in-flight
    /// run) may do so on any executor, so `deinit` does not free in place: it enqueues the free on
    /// `queue`, behind every run already queued — the only place llama.cpp objects are ever touched.
    final class ModelBox: @unchecked Sendable {
        // Safe: `pointer` is immutable and only dereferenced on LlamaEngine.queue; the free is
        // enqueued from deinit, so no executor other than `queue` ever calls into llama.cpp.
        let pointer: OpaquePointer
        private let queue: DispatchQueue
        init(_ pointer: OpaquePointer, queue: DispatchQueue) { self.pointer = pointer; self.queue = queue }
        deinit {
            let address = UInt(bitPattern: pointer)   // OpaquePointer is not Sendable; the address is
            queue.async { llama_model_free(OpaquePointer(bitPattern: address)) }
        }
    }

    /// Owns the `llama_context` pointer and keeps its `ModelBox` alive, so the context is always
    /// freed (enqueued) before the model it was created from.
    final class ContextBox: @unchecked Sendable {
        // Safe: same rule as ModelBox — immutable pointer, dereferenced only on `queue`, freed on `queue`.
        let pointer: OpaquePointer
        let model: ModelBox
        private let queue: DispatchQueue
        init(_ pointer: OpaquePointer, model: ModelBox, queue: DispatchQueue) { self.pointer = pointer; self.model = model; self.queue = queue }
        deinit {
            let address = UInt(bitPattern: pointer)
            queue.async { llama_free(OpaquePointer(bitPattern: address)) }
        }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    public func isReady() async -> Bool { context != nil }

    public func load(modelAt url: URL) async throws {
        let path = url.path
        let parameters = parameters
        let queue = queue
        let box: ContextBox = try await onQueue {
            _ = Self.backendInit
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = parameters.gpuLayers
            guard let model = llama_model_load_from_file(path, modelParams) else { throw LLMError.modelLoadFailed(path) }
            let modelBox = ModelBox(model, queue: queue)
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = UInt32(parameters.contextTokens)
            contextParams.n_batch = UInt32(parameters.batchTokens)
            contextParams.n_threads = parameters.threadCount
            contextParams.n_threads_batch = parameters.threadCount
            guard let context = llama_init_from_model(model, contextParams) else { throw LLMError.modelLoadFailed(path) }
            return ContextBox(context, model: modelBox, queue: queue)
        }
        context = box   // the previous box (if any) is released here; its deinit enqueues the frees on `queue`
    }

    public func unload() async {
        context = nil
    }

    public func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard let context else { throw LLMError.modelNotLoaded }
        let model = context.model
        let limit = Int(parameters.contextTokens)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await onQueue {
                let vocab = llama_model_get_vocab(model.pointer)
                let text = try Self.applyTemplate(model: model.pointer, prompt: prompt)
                let tokens = try Self.tokenize(vocab: vocab, text: text)
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
