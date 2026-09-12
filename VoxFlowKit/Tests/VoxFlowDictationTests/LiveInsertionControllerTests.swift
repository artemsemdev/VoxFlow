import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Live insertion controller", .timeLimit(.minutes(1)))
struct LiveInsertionControllerTests {
    private actor Inserter: LiveTextInserting {
        let calls = Recorder<String>()
        let entered = Gate(), release = Gate(), resumed = Gate()
        let pause: String?
        init(pause: String? = nil) { self.pause = pause }
        var context: LiveInsertionContext?
        func insert(_ text: String, cursorOffset: Int?) -> InsertionResult {
            calls.append("insert:" + text); return .inserted(appName: "TextEdit")
        }
        func beginLiveInsertion(_ context: LiveInsertionContext) { self.context = context; calls.append("begin") }
        func updateLiveInsertion(_ text: String, context: LiveInsertionContext) async {
            if pause == "partial" { await entered.open(); await release.wait() }
            if context.isActive { calls.append("partial:" + text) }
            if pause == "partial" { await resumed.open() }
        }
        func finishLiveInsertion(_ text: String, cursorOffset: Int?, context: LiveInsertionContext) async -> InsertionResult? {
            if pause == "final" { await entered.open(); await release.wait() }
            let valid = context.isActive
            if valid { calls.append("final:" + text) }
            if pause == "final" { await resumed.open() }
            return valid ? .inserted(appName: "TextEdit") : nil
        }
        var active: Bool { context?.isActive == true }
    }
    private struct Transcriber: DictationTranscribing {
        let received: Recorder<Int>
        func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                        onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
            var count = 0
            for await _ in chunks {
                count += 1
                await onEvent(.partialText(count == 1 ? "hello" : "hello world"))
                received.append(count)
            }
            return DictationResult(text: "Hello, world!", rawText: "hello world", segments: [],
                                   language: nil, duration: 2, lowConfidence: false)
        }
    }
    @Test("cumulative previews are awaited and final styling uses the same capture without a second insert",
          arguments: [false, true])
    func cumulative(ephemeral: Bool) async throws {
        let mic = FakeMicrophone(), inserter = Inserter(), received = Recorder<Int>(), saved = Recorder<Int>()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic,
            transcriber: Transcriber(received: received), inserter: inserter, clock: FakeClock(),
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in saved.append(1) },
            copyToClipboard: { _ in }, ephemeral: { ephemeral })
        await controller.shortcutDown(.pushToTalk)
        await mic.waitUntilCapturing()
        mic.emit(rms: 0.3, seconds: 1)
        await received.waitUntilCount(1)
        let initialCalls = inserter.calls.items
        let expected = ephemeral ? [] : ["begin", "partial:hello"]
        if initialCalls != expected { await controller.escape() }
        try #require(initialCalls == expected)
        mic.emit(rms: 0.3, seconds: 1)
        await received.waitUntilCount(2)
        await controller.pushToTalkReleased()
        await inserter.calls.waitUntilCount(ephemeral ? 1 : 4)
        #expect(inserter.calls.items == (ephemeral ? ["insert:Hello, world!"] :
            ["begin", "partial:hello", "partial:hello world", "final:Hello, world!"]))
        await controller.escape()
    }
    @Test("Escape invalidates the live context and keeps an already delivered preview")
    func cancel() async {
        let mic = FakeMicrophone(), inserter = Inserter(), received = Recorder<Int>()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic,
            transcriber: Transcriber(received: received), inserter: inserter, clock: FakeClock(),
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        await controller.shortcutDown(.pushToTalk)
        await mic.waitUntilCapturing()
        mic.emit(rms: 0.3, seconds: 1)
        await received.waitUntilCount(1)
        await controller.escape()
        #expect(await inserter.active == false)
        #expect(inserter.calls.items == ["begin", "partial:hello"])
    }

    @Test("suspended partial and final callbacks cannot write after Escape starts a newer capture",
          arguments: ["partial", "final"])
    func suspended(pause: String) async {
        let mic = FakeMicrophone(), inserter = Inserter(pause: pause), received = Recorder<Int>()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic,
            transcriber: Transcriber(received: received), inserter: inserter, clock: FakeClock(),
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        await controller.shortcutDown(.pushToTalk)
        await mic.waitUntilCapturing()
        mic.emit(rms: 0.3, seconds: 1)
        if pause == "final" {
            await received.waitUntilCount(1)
            await controller.pushToTalkReleased()
        }
        await inserter.entered.wait()
        await controller.escape()
        let before = inserter.calls.items
        await controller.shortcutDown(.pushToTalk)
        await inserter.calls.waitUntilCount(before.count + 1)
        await inserter.release.open()
        await inserter.resumed.wait()
        #expect(inserter.calls.items == before + ["begin"])
        #expect(await inserter.active)
        await controller.escape()
    }
}
