import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Processing deadline", .timeLimit(.minutes(1)))
struct ProcessingDeadlineTests {
    @Test("finish stamps the current capture before closing its feed and cannot affect an aborted capture")
    func captureLocalDeadline() async throws {
        let clock = FakeClock(), mic = FakeMicrophone(), probe = DeadlineProbe()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: probe,
            inserter: FakeTextInserter(), clock: clock,
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        var states = await controller.states().makeAsyncIterator()
        for index in 0..<2 {
            await controller.fnDown()
            guard case .armed = await states.next() else { Issue.record("expected armed"); return }
            await mic.waitUntilCapturing()
            await probe.providers.waitUntilCount(index + 1)
            #expect(probe.providers.items[index]() == nil)
            await clock.waitForSleepers(1)
            await clock.advance(by: 0.25)
            guard case .listening = await states.next() else { Issue.record("expected listening"); return }
            if index == 0 {
                await controller.escape()
                #expect(await states.next() == .discarded)
                await mic.waitUntilStopped()
            } else {
                var nextConfig = FlowBarConfig()
                nextConfig.processingTimeout = 7
                await controller.updateConfig(nextConfig)
                await controller.fnUp()
                guard case .processing = await states.next() else { Issue.record("expected processing"); return }
            }
        }
        await probe.finishedFeeds.waitUntilCount(2)
        #expect(probe.providers.items[0]() == nil)
        #expect(probe.providers.items[1]() == 20.5)
        #expect(probe.finishedFeeds.items.contains(20.5))
        await controller.escape()
        await probe.release.open()
    }
}

private struct DeadlineProbe: DictationTranscribing {
    let providers = Recorder<@Sendable () -> TimeInterval?>()
    let finishedFeeds = Recorder<TimeInterval?>()
    let release = Gate()
    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @escaping @Sendable (DictationEvent) async -> Void) async throws -> DictationResult {
        try await transcribe(chunks, options: options, processingDeadline: { nil }, onEvent: onEvent)
    }
    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    processingDeadline: @escaping @Sendable () -> TimeInterval?,
                    onEvent: @escaping @Sendable (DictationEvent) async -> Void) async throws -> DictationResult {
        providers.append(processingDeadline)
        for await _ in chunks {}
        finishedFeeds.append(processingDeadline())
        await release.wait()
        return .empty
    }
}
