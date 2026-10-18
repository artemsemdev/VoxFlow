import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Styled deadline", .timeLimit(.minutes(1)))
struct StyledDeadlineTests {
    @Test("a slow final speech window leaves only the remaining styling time before insertion")
    func slowFlushStillInserts() async throws {
        let clock = FakeClock(), mic = FakeMicrophone(), backend = WaitingGenerationBackend(clock: clock)
        let fixture = StyledTranscriberTests()
        let transcriber = StyledTranscriber(base: SlowFlushTranscriber(clock: clock),
            styler: LlamaStyler(backend: backend, clock: clock),
            settings: StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: .formal, removeFillers: true,
                autoPunctuate: true, snippetSayPrefix: false)), content: fixture.snapshots(),
            frontmost: FrontmostBox(), clipboard: { nil }, now: Date.init)
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber,
            inserter: FakeTextInserter(), clock: clock,
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        var states = await controller.states().makeAsyncIterator()
        var results = await controller.results().makeAsyncIterator()
        await controller.fnDown()
        guard case .armed = await states.next() else { Issue.record("expected armed"); return }
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(1)
        await clock.advance(by: 0.25)
        guard case .listening = await states.next() else { Issue.record("expected listening"); return }
        await controller.fnUp()
        guard case .processing = await states.next() else { Issue.record("expected processing"); return }
        await clock.waitForSleepers(3) // final speech flush + both processing timers
        await clock.advance(by: 13)
        await backend.started.wait()
        await clock.waitForSleepers(3) // backend + shortened style deadline + processing timeout
        await clock.advance(by: 6)
        let result = try #require(await results.next())
        #expect(result.text == "We should meet on thursday afternoon.")
        #expect(result.rawText == "um we should meet on thursday afternoon")
        #expect(clock.now() == 19.25) // processing started at0.25; one second remains for completion
        guard case .inserted = await controller.state else { Issue.record("expected insertion before timeout"); return }
    }

    @Test("existential dispatch carries the processing deadline with a completion margin")
    func forwardsDeadline() async throws {
        let spy = DeadlineOptionsStyler()
        let fixture = StyledTranscriberTests()
        let transcriber: any DictationTranscribing = StyledTranscriber(
            base: FakeDictationTranscriber(result: .empty), styler: spy,
            settings: StylingSettingsBox(StylingSettingsSnapshot(defaultStyle: .formal, removeFillers: true,
                autoPunctuate: true, snippetSayPrefix: false)), content: fixture.snapshots(),
            frontmost: FrontmostBox(), clipboard: { nil }, now: Date.init)
        _ = try await transcriber.transcribe(fixture.emptyFeed(), options: TranscriptionOptions(),
            processingDeadline: { 20 }) { _ in }
        #expect(await spy.deadlines == [19])
        _ = try await transcriber.transcribe(fixture.emptyFeed(), options: TranscriptionOptions()) { _ in }
        #expect(await spy.deadlines == [19, nil])
    }
}

private actor DeadlineOptionsStyler: TextStyler {
    private(set) var deadlines: [Double?] = []
    func style(_ raw: String, options: StylingOptions) async throws -> StyledText {
        deadlines.append(options.generationDeadline)
        return StyledText(text: raw, fillersRemoved: 0)
    }
}

private struct SlowFlushTranscriber: DictationTranscribing {
    let clock: FakeClock
    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @escaping @Sendable (DictationEvent) async -> Void) async throws -> DictationResult {
        for await _ in chunks {}
        try await clock.sleep(for: 13)
        let raw = "um we should meet on thursday afternoon"
        return DictationResult(text: raw, rawText: raw, segments: [], language: nil, duration: 1, lowConfidence: false)
    }
}

private struct WaitingGenerationBackend: LLMBackend {
    let clock: FakeClock
    let started = Gate()
    func isReady() async -> Bool { true }
    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        await started.open()
        try await clock.sleep(for: 100)
        return "unreachable"
    }
}
