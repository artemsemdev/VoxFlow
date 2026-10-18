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
    private let beforeBackendPreparation: @Sendable () throws -> Void

    public init(parameters: LlamaParameters = LlamaParameters(availableCores: ProcessInfo.processInfo.activeProcessorCount)) {
        self.parameters = parameters
        beforeBackendPreparation = {}
    }

    /// A failing preparation hook lets preflight tests prove they never enter the native backend.
    init(beforeBackendPreparation: @escaping @Sendable () throws -> Void) {
        parameters = LlamaParameters(availableCores: ProcessInfo.processInfo.activeProcessorCount)
        self.beforeBackendPreparation = beforeBackendPreparation
    }

    /// Owns the native pair: the context must be destroyed before its model. Both are
    /// released on the native queue after earlier uses, including when Swift references linger.
    final class ContextBox: @unchecked Sendable {
        // Safe: immutable pointers are dereferenced only on LlamaEngine.queue. Engine operations
        // register their queue work while actor-isolated; unload detaches this box before release.
        let pointer: OpaquePointer
        let model: OpaquePointer
        private let lifetime: LlamaNativeLifetime

        init(_ pointer: OpaquePointer, model: OpaquePointer, queue: DispatchQueue,
             releaseNative: @escaping @Sendable (OpaquePointer, OpaquePointer) -> Void = {
                 llama_free($0)
                 llama_model_free($1)
             }) {
            self.pointer = pointer
            self.model = model
            let contextAddress = UInt(bitPattern: pointer), modelAddress = UInt(bitPattern: model)
            lifetime = LlamaNativeLifetime(queue: queue) {
                releaseNative(OpaquePointer(bitPattern: contextAddress)!, OpaquePointer(bitPattern: modelAddress)!)
            }
        }

        func release(isolation: isolated (any Actor)? = #isolation) async { await lifetime.release() }
        deinit { lifetime.releaseInBackground() }
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
        let beforeBackendPreparation = beforeBackendPreparation
        let box: ContextBox = try await onQueue {
            // Reject invalid inputs before native initialization compiles Metal kernels.
            guard url.isFileURL,
                  let file = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
                  file.isRegularFile == true, file.isReadable == true else { throw LLMError.modelLoadFailed(path) }
            try beforeBackendPreparation()
            _ = Self.backendInit
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = parameters.gpuLayers
            guard let model = llama_model_load_from_file(path, modelParams) else { throw LLMError.modelLoadFailed(path) }
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = UInt32(parameters.contextTokens)
            contextParams.n_batch = UInt32(parameters.batchTokens)
            contextParams.n_threads = parameters.threadCount
            contextParams.n_threads_batch = parameters.threadCount
            guard let context = llama_init_from_model(model, contextParams) else {
                llama_model_free(model)
                throw LLMError.modelLoadFailed(path)
            }
            return ContextBox(context, model: model, queue: queue)
        }
        let previous = context
        context = box
        await previous?.release()
    }

    public func unload() async {
        let previous = context
        context = nil
        await previous?.release()
    }

    public func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard let context else { throw LLMError.modelNotLoaded }
        let limit = Int(parameters.contextTokens)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await onQueue {
                guard !cancel.isSet else { throw LLMError.cancelled }
                let model = context.model
                let vocab = llama_model_get_vocab(model)
                let text = try Self.applyTemplate(model: model, prompt: prompt)
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
