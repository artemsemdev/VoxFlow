import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Model-load lifecycle", .timeLimit(.minutes(1)))
struct ModelLoadLifecycleTests {
    @Test(arguments: [HeldModelLoads.Outcome.succeed, .fail])
    fileprivate func staleCancelledLoadCannotFinishNewCapture(oldOutcome: HeldModelLoads.Outcome) async throws {
        let microphone = FakeMicrophone()
        let monitor = UseMonitor()
        let loads = HeldModelLoads(first: oldOutcome)
        let controller = DictationController(
            config: FlowBarConfig(), microphone: microphone,
            transcriber: FakeDictationTranscriber(result: DictationResult(
                text: "hello world", rawText: "hello world", segments: [], language: nil,
                duration: 1, lowConfidence: false)),
            inserter: FakeTextInserter(), clock: FakeClock(),
            preflight: {
                Preflight(excludedApp: nil, secureInput: false, microphone: .granted,
                          model: .installedNotLoaded)
            },
            loadModel: { try await loads.load() }, options: { TranscriptionOptions() },
            onSave: { _, _ in }, copyToClipboard: { _ in }, microphoneUse: monitor)

        await controller.shortcutDown(.handsFree)
        await loads.started[0].wait()
        let oldTask = try #require(await controller.activeModelLoadTask)

        monitor.setCurrent(.inUse(by: "Zoom"))
        var states = await controller.states().makeAsyncIterator()
        microphone.fail(.inUse(by: "Zoom"))
        #expect(await states.next() == .micUnavailable(.inUse(by: "Zoom")))
        await monitor.subscribed.wait()
        monitor.send(.available)
        await loads.started[1].wait()
        let newTask = try #require(await controller.activeModelLoadTask)
        #expect(isLoading(await controller.state))

        await loads.releases[0].open()
        await oldTask.value

        #expect(isLoading(await controller.state))
        #expect(await controller.activeModelLoadTask != nil)

        await loads.releases[1].open()
        await newTask.value
        #expect(await controller.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await controller.escape()
    }
}

private func isLoading(_ state: FlowBarState) -> Bool {
    if case .loadingModel = state { true } else { false }
}

private final class HeldModelLoads: Sendable {
    enum Outcome: Sendable { case succeed, fail }
    struct Failure: Error {}

    let started = [Gate(), Gate()]
    let releases = [Gate(), Gate()]
    private let calls = Mutex(0)
    private let outcomes: [Outcome]

    init(first: Outcome) { outcomes = [first, .succeed] }

    func load() async throws {
        let index = calls.withLock { value in defer { value += 1 }; return value }
        await started[index].open()
        await releases[index].wait() // Deliberately models native work that ignores cancellation.
        if outcomes[index] == .fail { throw Failure() }
    }
}

private final class UseMonitor: MicrophoneUseMonitoring, Sendable {
    private struct State {
        var value = MicrophoneUseState.unknown
        var continuation: AsyncStream<MicrophoneUseState>.Continuation?
    }
    private let state = Mutex(State())
    let subscribed = Gate()

    func currentState() -> MicrophoneUseState { state.withLock { $0.value } }
    func freshState() -> MicrophoneUseState { currentState() }
    func changes() -> AsyncStream<MicrophoneUseState> {
        AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            Task { await subscribed.open() }
        }
    }
    func setCurrent(_ value: MicrophoneUseState) { state.withLock { $0.value = value } }
    func send(_ value: MicrophoneUseState) {
        let continuation = state.withLock { state in
            state.value = value
            return state.continuation
        }
        continuation?.yield(value)
    }
}
