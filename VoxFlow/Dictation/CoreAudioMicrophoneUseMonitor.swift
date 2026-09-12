@preconcurrency import CoreAudio
import Foundation
import Synchronization
import VoxFlowCore

protocol CoreAudioHogAccessing: Sendable {
    func defaultInputDevice() -> AudioObjectID?
    func hogOwnerPID(of device: AudioObjectID) -> pid_t?
    func observeDefaultInput(_ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)?
    func observeHogMode(of device: AudioObjectID, _ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)?
}

protocol CoreAudioObservation: Sendable { func cancel() }

/// Public CoreAudio's hog-mode PID is the only evidence used to name another app.
/// All reads, listener callbacks, rebinds, and publications are ordered on the executor.
final class CoreAudioMicrophoneUseMonitor: MicrophoneUseMonitoring, @unchecked Sendable {
    private let access: any CoreAudioHogAccessing
    private let resolveName: @Sendable (pid_t) -> String?
    private let executor = DispatchQueue(label: "dev.artemsem.voxflow.microphone-use-monitor")
    private var snapshot: MicrophoneUseState = .unknown
    private var continuations: [UUID: AsyncStream<MicrophoneUseState>.Continuation] = [:]
    private var defaultObservation: (any CoreAudioObservation)?
    private var hogObservation: (any CoreAudioObservation)?
    private var device: AudioObjectID?

    init(access: any CoreAudioHogAccessing, resolveName: @escaping @Sendable (pid_t) -> String?) {
        self.access = access
        self.resolveName = resolveName
        executor.sync {
            defaultObservation = access.observeDefaultInput { [weak self] in
                self?.executor.async { [weak self] in self?.rebind() }
            }
            rebind()
        }
    }

    convenience init(resolveName: @escaping @Sendable (pid_t) -> String?) {
        self.init(access: SystemCoreAudioHogAccess(), resolveName: resolveName)
    }

    deinit {
        // Deinitialization is exclusive, including when the last strong owner was a callback
        // executing on the executor; synchronously re-entering that queue would trap.
        defaultObservation?.cancel()
        hogObservation?.cancel()
        continuations.values.forEach { $0.finish() }
    }

    func currentState() -> MicrophoneUseState { executor.sync { snapshot } }

    /// Synchronously refreshes hardware state on the same executor as callbacks. This closes the
    /// engine-start race even when CoreAudio has not delivered its property notification yet.
    func freshState() -> MicrophoneUseState {
        executor.sync {
            rebind()
            return snapshot
        }
    }

    func changes() -> AsyncStream<MicrophoneUseState> {
        AsyncStream { continuation in
            let id = UUID()
            executor.sync { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.executor.async { [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    private func rebind() {
        let nextDevice = access.defaultInputDevice()
        guard nextDevice != device else {
            if let nextDevice { refresh(nextDevice) } else { publish(.unknown) }
            return
        }
        hogObservation?.cancel()
        hogObservation = nil
        device = nextDevice
        guard let nextDevice else {
            publish(.unknown)
            return
        }
        hogObservation = access.observeHogMode(of: nextDevice) { [weak self] in
            self?.executor.async { [weak self] in
                guard self?.device == nextDevice else { return }
                self?.refresh(nextDevice)
            }
        }
        refresh(nextDevice)
    }

    private func refresh(_ device: AudioObjectID) {
        let state: MicrophoneUseState
        if let pid = access.hogOwnerPID(of: device) {
            if pid == -1 {
                state = .available
            } else if pid > 0 {
                state = .inUse(by: resolveName(pid))
            } else {
                state = .unknown
            }
        } else {
            state = .unknown
        }
        publish(state)
    }

    private func publish(_ next: MicrophoneUseState) {
        guard next != snapshot else { return }
        snapshot = next
        continuations.values.forEach { $0.yield(next) }
    }
}

private final class SystemCoreAudioHogAccess: CoreAudioHogAccessing, Sendable {
    private let listenerQueue = DispatchQueue(label: "dev.artemsem.voxflow.microphone-use")

    func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    func hogOwnerPID(of device: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout.size(ofValue: pid))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    func observeDefaultInput(_ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)? {
        observe(AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice, changed)
    }

    func observeHogMode(of device: AudioObjectID, _ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)? {
        observe(device, selector: kAudioDevicePropertyHogMode, changed)
    }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
        _ changed: @escaping @Sendable () -> Void) -> (any CoreAudioObservation)? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr else { return nil }
        return SystemCoreAudioObservation(
            object: object, address: address, queue: listenerQueue, block: block)
    }
}

/// CoreAudio does not annotate its copied listener block as Sendable. The other fields are
/// immutable and the mutex serializes removal.
private final class SystemCoreAudioObservation: CoreAudioObservation, @unchecked Sendable {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let active = Mutex(true)

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    func cancel() {
        let shouldRemove = active.withLock { active in
            defer { active = false }
            return active
        }
        guard shouldRemove else { return }
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
    deinit { cancel() }
}
