import Foundation
import VoxFlowCore
import whisper

/// `SpeechEngine` over whisper.cpp. The C context is touched only on `queue`; the actor
/// serializes calls and awaits the queue, so long transcriptions never block a cooperative thread.
public actor WhisperCppEngine: SpeechEngine {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.whisper", qos: .userInitiated)
    private var context: ContextBox?

    public init() {}

    /// Owns the `whisper_context` pointer and frees it when the engine goes away.
    final class ContextBox: @unchecked Sendable {
        // Safe: the pointer is only dereferenced on WhisperCppEngine.queue while runs are in flight;
        // deinit runs when the last reference (held by the engine or an in-flight run) goes away,
        // so nothing can be using it.
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { whisper_free(pointer) }
    }

    /// State shared with the C callbacks during one `whisper_full` call.
    final class RunState: @unchecked Sendable {
        // Safe: written only from whisper.cpp's callbacks, which run on `queue` inside whisper_full.
        let continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation
        let isCancelled: @Sendable () -> Bool
        var emitted: Int32 = 0
        init(continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation, isCancelled: @escaping @Sendable () -> Bool) {
            self.continuation = continuation
            self.isCancelled = isCancelled
        }
    }

    public func load(modelAt url: URL) async throws {
        let path = url.path
        let box: ContextBox = try await onQueue {
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let pointer = whisper_init_from_file_with_params(path, params) else {
                throw SpeechEngineError.modelLoadFailed(path)
            }
            return ContextBox(pointer)
        }
        context = box
    }

    public func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        guard let context else { throw SpeechEngineError.modelNotLoaded }
        let samples = audio.samples
        let threads = Int32(WhisperParameters(options: TranscriptionOptions(), availableCores: ProcessInfo.processInfo.activeProcessorCount).threadCount)
        return try await onQueue {
            var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
            let languageID: Int32 = samples.withUnsafeBufferPointer { buffer in
                guard whisper_pcm_to_mel(context.pointer, buffer.baseAddress, Int32(buffer.count), threads) == 0 else { return -1 }
                return whisper_lang_auto_detect(context.pointer, 0, threads, &probabilities)
            }
            guard languageID >= 0 else { throw SpeechEngineError.transcriptionFailed(code: languageID) }
            let code = String(cString: whisper_lang_str(languageID))
            return LanguageDetection(code: code, confidence: Double(probabilities[Int(languageID)]))
        }
    }

    public nonisolated func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        AsyncThrowingStream { continuation in
            // The stream builder runs synchronously on the caller's task, before any suspension. If that
            // task is already cancelled, `AsyncThrowingStream.next()` would otherwise end iteration
            // silently on its own cancellation check, racing ahead of (and swallowing) any error the
            // producer below finishes with — so finish synchronously here instead of spawning the task.
            guard !Task.isCancelled else {
                continuation.finish(throwing: SpeechEngineError.cancelled)
                return
            }
            let task = Task {
                do {
                    try await self.run(audio, options: options, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ audio: AudioSamples, options: TranscriptionOptions,
                     continuation: AsyncThrowingStream<SegmentEvent, Error>.Continuation) async throws {
        guard let context else { throw SpeechEngineError.modelNotLoaded }
        let mapped = WhisperParameters(options: options, availableCores: ProcessInfo.processInfo.activeProcessorCount)
        let samples = audio.samples
        // onCancel is tied to the producer Task created in transcribe(); the consumer's cancellation
        // reaches it through continuation.onTermination → task.cancel(). See #125 for the stream-side
        // caveat.
        let cancelFlag = CancelFlag()
        let runState = RunState(continuation: continuation, isCancelled: { cancelFlag.isSet })

        try await withTaskCancellationHandler {
            try await onQueue {
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.n_threads = Int32(mapped.threadCount)
                params.print_progress = false
                params.print_realtime = false
                params.print_special = false
                params.print_timestamps = false
                params.no_speech_thold = mapped.noSpeechThreshold
                params.single_segment = false

                let languageC = mapped.language.flatMap { strdup($0) }
                let promptC = mapped.initialPrompt.flatMap { strdup($0) }
                defer { free(languageC); free(promptC) }
                params.language = languageC.map { UnsafePointer($0) }
                params.detect_language = false
                params.initial_prompt = promptC.map { UnsafePointer($0) }

                let unmanaged = Unmanaged.passRetained(runState)
                defer { unmanaged.release() }
                let userData = unmanaged.toOpaque()

                params.new_segment_callback_user_data = userData
                params.new_segment_callback = { ctx, _, _, userData in
                    guard let ctx, let userData else { return }
                    let state = Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue()
                    let total = whisper_full_n_segments(ctx)
                    while state.emitted < total {
                        let i = state.emitted
                        let start = Double(whisper_full_get_segment_t0(ctx, i)) / 100
                        let end = Double(whisper_full_get_segment_t1(ctx, i)) / 100
                        let text = String(cString: whisper_full_get_segment_text(ctx, i))
                        let tokenCount = whisper_full_n_tokens(ctx, i)
                        let confidence: Double? = tokenCount > 0
                            ? (0..<tokenCount).reduce(0.0) { $0 + Double(whisper_full_get_token_p(ctx, i, $1)) } / Double(tokenCount)
                            : nil
                        if let segment = TranscriptSegment(start: start, end: end, text: text, confidence: confidence) {
                            state.continuation.yield(.segment(segment))
                        }
                        state.emitted += 1
                    }
                }
                params.progress_callback_user_data = userData
                params.progress_callback = { _, _, progress, userData in
                    guard let userData else { return }
                    let state = Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue()
                    state.continuation.yield(.progress(min(max(Double(progress) / 100, 0), 1)))
                }
                params.abort_callback_user_data = userData
                params.abort_callback = { userData in
                    guard let userData else { return false }
                    return Unmanaged<RunState>.fromOpaque(userData).takeUnretainedValue().isCancelled()
                }

                let code = samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context.pointer, params, buffer.baseAddress, Int32(buffer.count))
                }
                if runState.isCancelled() { throw SpeechEngineError.cancelled }
                guard code == 0 else { throw SpeechEngineError.transcriptionFailed(code: code) }
                runState.continuation.yield(.progress(1))
            }
        } onCancel: {
            cancelFlag.set()
        }
    }

    /// Thread-safe cancellation flag readable from a C callback.
    final class CancelFlag: @unchecked Sendable {
        // Safe: a single Bool guarded by a lock.
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    /// Runs `body` on the engine's serial queue and resumes when it finishes.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
