import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

/// Fake `InputDeviceProviding` — a mutable `name` so a test can simulate a device appearing or
/// disappearing between `refreshDevice()` calls.
private final class FakeInputDeviceProvider: InputDeviceProviding, @unchecked Sendable {
    private struct State {
        var name: String?
        var continuation: AsyncStream<String?>.Continuation?
        var subscriptions = 0
        var terminations = 0
        var order: [String] = []
    }
    private let state: Mutex<State>
    private let eventOnSubscribe: String?

    init(name: String? = "MacBook Pro Microphone", eventOnSubscribe: String? = nil) {
        state = Mutex(State(name: name))
        self.eventOnSubscribe = eventOnSubscribe
    }
    var name: String? {
        get { state.withLock { $0.name } }
        set { state.withLock { $0.name = newValue } }
    }
    var subscriptions: Int { state.withLock { $0.subscriptions } }
    var terminations: Int { state.withLock { $0.terminations } }
    var order: [String] { state.withLock { $0.order } }

    func defaultInputName() -> String? {
        state.withLock { $0.order.append("refresh"); return $0.name }
    }

    func changes() -> AsyncStream<String?> {
        let (stream, continuation) = AsyncStream<String?>.makeStream()
        state.withLock {
            $0.subscriptions += 1
            $0.order.append("subscribe")
            $0.continuation = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.terminations += 1; $0.continuation = nil }
        }
        if let eventOnSubscribe { continuation.yield(eventOnSubscribe) }
        return stream
    }

    func emit(_ name: String?) {
        let continuation = state.withLock { state -> AsyncStream<String?>.Continuation? in
            state.name = name
            return state.continuation
        }
        continuation?.yield(name)
    }
}

@Suite("AudioViewModel") @MainActor
struct AudioViewModelTests {
    /// Minimal `DictationCoordinator` — `AudioViewModel` only reads `.levels` off it, which starts
    /// at 14 zeros and never changes unless something calls `reportLevel`/`start()`.
    func makeCoordinator() -> DictationCoordinator {
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
                                              transcriber: FakeDictationTranscriber(result: DictationResult(text: "", rawText: "", segments: [], language: nil, duration: 0, lowConfidence: false)),
                                              inserter: FakeTextInserter(), clock: FakeClock(),
                                              preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                              loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        return DictationCoordinator(controller: controller, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                    permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                    navigation: Navigation())
    }

    @Test("hasDevice reflects the provider's name, and clears when it disappears on refresh")
    func hasDeviceReflectsProvider() {
        let devices = FakeInputDeviceProvider(name: "MacBook Pro Microphone")
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = AudioViewModel(devices: devices, settings: settings, dictation: makeCoordinator())
        #expect(model.hasDevice)
        #expect(model.deviceName == "MacBook Pro Microphone")

        devices.name = nil
        #expect(model.hasDevice)               // stale until refreshed — no surprise flips mid-render
        model.refreshDevice()
        #expect(!model.hasDevice)
        #expect(model.deviceName == nil)
    }

    @Test("no device at construction reports hasDevice == false")
    func noDeviceAtStart() {
        let model = AudioViewModel(devices: FakeInputDeviceProvider(name: nil), settings: DictationSettings(store: InMemoryKeyValueStore()),
                                   dictation: makeCoordinator())
        #expect(!model.hasDevice)
        #expect(model.deviceName == nil)
    }

    @Test("silenceStop binds to DictationSettings and clamps through it")
    func silenceStopBindsAndClamps() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = AudioViewModel(devices: FakeInputDeviceProvider(), settings: settings, dictation: makeCoordinator())
        #expect(model.silenceStop == 3)
        model.silenceStop = 7
        #expect(model.silenceStop == 7 && settings.silenceStop == 7)
        model.silenceStop = 42
        #expect(model.silenceStop == 10 && settings.silenceStop == 10)   // clamped to the 1...10 range
        model.silenceStop = -5
        #expect(model.silenceStop == 1)
    }

    @Test("levels mirror the coordinator's, flat at construction")
    func levelsMirrorCoordinator() {
        let coordinator = makeCoordinator()
        let model = AudioViewModel(devices: FakeInputDeviceProvider(), settings: DictationSettings(store: InMemoryKeyValueStore()), dictation: coordinator)
        #expect(model.levels == coordinator.levels)
        #expect(model.levels.allSatisfy { $0 == 0 })
    }

    @Test("subscribes before refresh so a concurrent default-device event is not lost")
    func liveDeviceEvents() async {
        let devices = FakeInputDeviceProvider(name: "Built-in", eventOnSubscribe: "Studio Display Microphone")
        let connected = AudioViewModel(devices: devices,
                                       settings: DictationSettings(store: InMemoryKeyValueStore()),
                                       dictation: makeCoordinator())
        let task = Task { await connected.observeDeviceChanges() }
        for _ in 0..<1_000 where connected.deviceName != "Studio Display Microphone" { await Task.yield() }
        #expect(connected.deviceName == "Studio Display Microphone")
        #expect(devices.order.suffix(2) == ["subscribe", "refresh"])
        task.cancel()
        await task.value
    }

    @Test("an open Audio page follows connect/disconnect and releases its listener on cancellation")
    func connectionLifetime() async {
        let devices = FakeInputDeviceProvider(name: nil)
        let model = AudioViewModel(devices: devices, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                   dictation: makeCoordinator())
        let task = Task { await model.observeDeviceChanges() }
        for _ in 0..<1_000 where devices.subscriptions == 0 { await Task.yield() }
        #expect(devices.subscriptions == 1 && model.deviceName == nil)

        devices.emit("USB Microphone")
        for _ in 0..<1_000 where model.deviceName != "USB Microphone" { await Task.yield() }
        #expect(model.deviceName == "USB Microphone")
        devices.emit(nil)
        for _ in 0..<1_000 where model.deviceName != nil { await Task.yield() }
        #expect(model.deviceName == nil)

        task.cancel()
        await task.value
        for _ in 0..<1_000 where devices.terminations == 0 { await Task.yield() }
        #expect(devices.terminations == 1)
    }
}
