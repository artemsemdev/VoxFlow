import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowTestSupport
@testable import VoxFlow

/// Regression test for the retain cycle `AppServices.live()`'s `DictationLevelSink` could close:
/// `dictation` (`DictationCoordinator`) → `controller` (`DictationController`, stored `let`) →
/// `microphone` (`MeteredMicrophone`, stored `let`) → its `onLevel` closure (stored `let`, retained
/// for the microphone's life) → captures the sink strongly → sink holds `dictation` back. `Fake…`
/// stand-ins can't reach `AppServices.live()` itself (real mic/Keychain), so this mirrors the exact
/// weak-box-inside-a-`Mutex` shape `DictationLevelSink` uses, wired the same way, and proves the
/// coordinator actually deallocates once nothing outside this scope holds it.
@Suite("DictationCoordinator level-sink retain cycle", .timeLimit(.minutes(1)))
@MainActor
struct DictationLevelSinkRetainCycleTests {
    /// Same shape as `AppServices.swift`'s private `DictationLevelSink`: a `Mutex`-boxed `weak var`,
    /// sound because the `weak var` only ever lives inside the mutex's protected storage.
    private final class WeakLevelSink: Sendable {
        private struct WeakBox { weak var coordinator: DictationCoordinator? }
        private let box = Mutex(WeakBox(coordinator: nil))
        func attach(_ coordinator: DictationCoordinator) { box.withLock { $0.coordinator = coordinator } }
        func report(_ rms: Float) {
            Task { @MainActor in self.box.withLock { $0.coordinator }?.reportLevel(rms) }
        }
    }

    @Test("coordinator deallocates even though the microphone's onLevel closure retains the sink")
    func deallocatesWhenReleased() async {
        weak var weakCoordinator: DictationCoordinator?
        do {
            let sink = WeakLevelSink()
            let controller = DictationController(
                config: FlowBarConfig(),
                microphone: MeteredMicrophone(base: FakeMicrophone()) { rms in sink.report(rms) },
                transcriber: FakeDictationTranscriber(result: .empty),
                inserter: FakeTextInserter(),
                clock: FakeClock(),
                preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                loadModel: {}, options: { TranscriptionOptions() },
                onSave: { _, _ in }, copyToClipboard: { _ in }
            )
            let coordinator = DictationCoordinator(controller: controller, settings: DictationSettings(store: InMemoryKeyValueStore()),
                                                   permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                                   navigation: Navigation())
            // The strong direction of the cycle this guards against: the sink must be attached
            // *after* the coordinator exists, exactly as `AppServices.live()` does.
            sink.attach(coordinator)
            coordinator.start()
            weakCoordinator = coordinator
            #expect(weakCoordinator != nil)
        }
        // `coordinator` (and every strong reference to it above) is out of scope now; give the
        // runtime a bounded number of turns to actually run the deallocation — ARC release itself
        // is synchronous, but this keeps the check honest about not asserting on the same line.
        for _ in 0..<50 { await Task.yield() }
        #expect(weakCoordinator == nil)
    }
}
