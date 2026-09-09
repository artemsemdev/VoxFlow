import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

/// Fake `InputDeviceProviding` — a mutable `name` so a test can simulate a device appearing or
/// disappearing between `refreshDevice()` calls.
private final class FakeInputDeviceProvider: InputDeviceProviding, @unchecked Sendable {
    var name: String?
    init(name: String? = "MacBook Pro Microphone") { self.name = name }
    func defaultInputName() -> String? { name }
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
}
