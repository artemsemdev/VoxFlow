import CoreAudio
import Foundation
import SwiftUI
import Synchronization
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlow

@Suite("Microphone exclusive-use detection")
struct MicrophoneUseMonitorTests {
    @Test("hog PID resolves to the owning application and publishes changes")
    func namedOwnerAndChanges() async {
        let access = FakeHogAccess(device: 42, pid: 700)
        let monitor = CoreAudioMicrophoneUseMonitor(access: access) { $0 == 700 ? "Zoom" : nil }
        #expect(monitor.currentState() == .inUse(by: "Zoom"))
        var changes = monitor.changes().makeAsyncIterator()
        access.setPID(-1)
        #expect(await changes.next() == .available)
        access.setPID(0)
        #expect(await changes.next() == .unknown)
        access.setPID(701)
        #expect(await changes.next() == .inUse(by: nil))
    }

    @Test("default-device changes rebind observation and property failures stay unknown")
    func rebindsDefaultDevice() {
        let access = FakeHogAccess(device: 42, pid: nil)
        let monitor = CoreAudioMicrophoneUseMonitor(access: access) { _ in "unused" }
        #expect(monitor.currentState() == .unknown)
        access.setDevice(84, pid: -1)
        #expect(monitor.currentState() == .available)
        #expect(access.observedDevices == [42, 84])
        #expect(access.cancelledHogObservations == 1)
    }

    @Test("overlapping default-device callbacks stay in causal order")
    func serializesRebinds() async {
        let access = FakeHogAccess(device: 42, pid: -1)
        let monitor = CoreAudioMicrophoneUseMonitor(access: access) {
            $0 == 700 ? "Zoom" : ($0 == 701 ? "FaceTime" : nil)
        }
        let gate = access.blockNextDefaultRead()
        let first = Task.detached { access.setDevice(84, pid: 700) }
        await gate.waitUntilEntered()
        access.setDevice(96, pid: 701)
        gate.release()
        await first.value

        #expect(monitor.currentState() == .inUse(by: "FaceTime"))
        #expect(access.observedDevices == [42, 84, 96])
    }

    @Test("last callback ownership tears down observers and finishes streams")
    func callbackOwnedDeinit() async {
        let access = FakeHogAccess(device: 42, pid: -1)
        var monitor: CoreAudioMicrophoneUseMonitor? = CoreAudioMicrophoneUseMonitor(
            access: access, resolveName: { _ in nil })
        let stream = monitor!.changes()
        let completion = Task {
            for await _ in stream {}
            return true
        }
        let gate = access.blockNextDefaultRead()
        access.setDevice(84, pid: -1)
        await gate.waitUntilEntered()
        monitor = nil
        gate.release()

        #expect(await completion.value)
        #expect(access.cancelledDefaultObservations == 1)
        #expect(access.cancelledHogDevices == [42, 84])
    }

    @Test("preflight names a known holder without capturing focus") @MainActor
    func preflightBusy() async {
        let focus = BusyCounter()
        let builder = PreflightBuilder(
            frontmost: BusyFrontmost(), permissions: BusyPermissions(), readiness: { .loaded },
            settings: DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()),
            microphoneUse: FixedUse(.inUse(by: "Zoom")), captureFocus: { _ in focus.increment() })
        let result = await builder.preflight()
        #expect(result.microphone == .inUse(by: "Zoom"))
        #expect(focus.value == 0)
    }

    @Test("engine-start classification blames an app only with hog evidence")
    func startFailureClassification() {
        #expect(MicrophoneSource(microphoneUse: FixedUse(.inUse(by: "FaceTime"))).classifiedStartError("failed")
                == .inUse(by: "FaceTime"))
        #expect(MicrophoneSource(microphoneUse: FixedUse(.available)).classifiedStartError("failed")
                == .engineFailed("failed"))
        #expect(MicrophoneSource(microphoneUse: FixedUse(.unknown)).classifiedStartError("failed")
                == .engineFailed("failed"))

        var machine = FlowBarMachine()
        _ = machine.handle(.fnDown(Preflight(excludedApp: nil, secureInput: false,
                                             microphone: .granted, model: .loaded)), now: 0)
        _ = machine.handle(.microphoneFailed(.engineFailed("failed")), now: 0.1)
        #expect(machine.state == .micUnavailable(.granted))

        machine = FlowBarMachine()
        _ = machine.handle(.fnDown(Preflight(excludedApp: nil, secureInput: false,
                                             microphone: .granted, model: .loaded)), now: 0)
        _ = machine.handle(.microphoneFailed(.inUse(by: "FaceTime")), now: 0.1)
        #expect(machine.state == .micUnavailable(.inUse(by: "FaceTime")))

        let access = FakeHogAccess(device: 42, pid: -1)
        let monitor = CoreAudioMicrophoneUseMonitor(access: access) { $0 == 700 ? "Zoom" : nil }
        access.setPID(700, notify: false)
        #expect(monitor.currentState() == .available)
        #expect(MicrophoneSource(microphoneUse: monitor).classifiedStartError("failed")
                == .inUse(by: "Zoom"))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct MicrophoneUseRenderTests {
    @Test("renders generic, named, and unknown-holder microphone failures in the production HUD")
    func render() throws {
        let states: [(String, FlowBarState)] = [
            ("generic", .micUnavailable(.granted)),
            ("named", .micUnavailable(.inUse(by: "Zoom"))),
            ("unknown-holder", .micUnavailable(.inUse(by: nil))),
        ]
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, state) in states {
            let content = FlowBarContent.make(state: state, elapsed: 0, mode: .pushToTalk)
            let host = NativeRenderHost(
                ZStack {
                    Color(red: 0xd9 / 255, green: 0xdb / 255, blue: 0xe0 / 255)
                    FlowBarView(content: content, levels: [])
                },
                size: NSSize(width: 420, height: 80))
            defer { host.close() }
            try host.capture(to: directory.appendingPathComponent("FlowBar-microphone-\(name).png"))
        }
    }
}

private struct FixedUse: MicrophoneUseMonitoring {
    let state: MicrophoneUseState
    init(_ state: MicrophoneUseState) { self.state = state }
    func currentState() -> MicrophoneUseState { state }
    func freshState() -> MicrophoneUseState { state }
    func changes() -> AsyncStream<MicrophoneUseState> { AsyncStream { $0.finish() } }
}

private final class BusyCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

private struct BusyFrontmost: FrontmostAppProviding {
    func frontmostApp() -> FrontmostApp { FrontmostApp(name: "Mail", bundleID: "com.apple.mail") }
    func secureInputEnabled() -> Bool { false }
}

private struct BusyPermissions: PermissionChecking {
    func microphone() -> PermissionState { .granted }
    func requestMicrophone() async -> PermissionState { .granted }
    func accessibilityTrusted(prompt: Bool) -> Bool { true }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
}

private final class FakeHogAccess: CoreAudioHogAccessing, Sendable {
    private struct State {
        var device: AudioObjectID?
        var pids: [AudioObjectID: pid_t?]
        var defaultHandler: (@Sendable () -> Void)?
        var hogHandlers: [AudioObjectID: @Sendable () -> Void] = [:]
        var observedDevices: [AudioObjectID] = []
        var cancelledDefaultObservations = 0
        var cancelledHogObservations = 0
        var cancelledHogDevices: [AudioObjectID] = []
        var nextDefaultReadGate: BlockingReadGate?
    }
    private let state: Mutex<State>
    var observedDevices: [AudioObjectID] { state.withLock { $0.observedDevices } }
    var cancelledDefaultObservations: Int { state.withLock { $0.cancelledDefaultObservations } }
    var cancelledHogObservations: Int { state.withLock { $0.cancelledHogObservations } }
    var cancelledHogDevices: [AudioObjectID] { state.withLock { $0.cancelledHogDevices } }

    init(device: AudioObjectID?, pid: pid_t?) {
        state = Mutex(State(device: device, pids: device.map { [$0: pid] } ?? [:]))
    }
    func defaultInputDevice() -> AudioObjectID? {
        let result = state.withLock { value -> (AudioObjectID?, BlockingReadGate?) in
            defer { value.nextDefaultReadGate = nil }
            return (value.device, value.nextDefaultReadGate)
        }
        result.1?.entered()
        return result.1?.awaitRelease(result.0) ?? result.0
    }
    func hogOwnerPID(of device: AudioObjectID) -> pid_t? { state.withLock { $0.pids[device] ?? nil } }
    func observeDefaultInput(_ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)? {
        state.withLock { $0.defaultHandler = changed }
        return FakeObservation { [weak self] in
            self?.state.withLock {
                $0.defaultHandler = nil
                $0.cancelledDefaultObservations += 1
            }
        }
    }
    func observeHogMode(of device: AudioObjectID, _ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)? {
        state.withLock { $0.observedDevices.append(device); $0.hogHandlers[device] = changed }
        return FakeObservation { [weak self] in self?.cancelHog(device) }
    }
    func setPID(_ pid: pid_t?, notify: Bool = true) {
        let handler = state.withLock { value in
            value.pids[value.device ?? 0] = pid
            return notify ? value.hogHandlers[value.device ?? 0] : nil
        }
        handler?()
    }
    func setDevice(_ device: AudioObjectID, pid: pid_t?) {
        let handler = state.withLock { value in
            value.device = device
            value.pids[device] = pid
            return value.defaultHandler
        }
        handler?()
    }
    private func cancelHog(_ device: AudioObjectID) {
        state.withLock {
            $0.hogHandlers[device] = nil
            $0.cancelledHogObservations += 1
            $0.cancelledHogDevices.append(device)
        }
    }
    func blockNextDefaultRead() -> BlockingReadGate {
        let gate = BlockingReadGate()
        state.withLock { $0.nextDefaultReadGate = gate }
        return gate
    }
}

private final class FakeObservation: CoreAudioObservation, Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>
    init(_ action: @escaping @Sendable () -> Void) { self.action = Mutex(action) }
    func cancel() { action.withLock { action in action?(); action = nil } }
}

private final class BlockingReadGate: Sendable {
    private struct State {
        var entered = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let mayReturn = DispatchSemaphore(value: 0)
    func entered() {
        let waiter = state.withLock { value -> CheckedContinuation<Void, Never>? in
            value.entered = true
            defer { value.waiter = nil }
            return value.waiter
        }
        waiter?.resume()
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let alreadyEntered = state.withLock { value in
                if !value.entered { value.waiter = continuation }
                return value.entered
            }
            if alreadyEntered { continuation.resume() }
        }
    }
    func release() { mayReturn.signal() }
    func awaitRelease<T>(_ value: T) -> T { mayReturn.wait(); return value }
}
