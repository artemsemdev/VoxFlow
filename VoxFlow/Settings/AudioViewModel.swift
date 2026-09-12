import AppKit
import Foundation
import VoxFlowCore

/// Settings › Audio (design ST-04, ST-04n). Thin: `deviceName`/`hasDevice` come from
/// `InputDeviceProviding` (re-read and observed while the tab is open, so ST-04n auto-recovers when
/// a device appears); `levels` mirrors the live
/// `DictationCoordinator` (flat while idle, per `DictationCoordinator.apply`); `silenceStop` is a
/// pass-through binding onto `DictationSettings`, which does its own 1…10 s clamping.
@Observable @MainActor
final class AudioViewModel {
    private let devices: any InputDeviceProviding
    private let settings: DictationSettings
    private let dictation: DictationCoordinator
    let microphoneTest: MicrophoneTestController?

    private(set) var deviceName: String?
    var hasDevice: Bool { deviceName != nil }
    var levels: [Float] { microphoneTest?.state == .recording ? microphoneTest!.levels : dictation.levels }
    var dictationBusy: Bool {
        switch dictation.state {
        case .idle, .paused: false
        default: !dictation.state.isDismissable
        }
    }
    var noiseSuppression: Bool {
        get { settings.noiseSuppression }
        set { settings.noiseSuppression = newValue }
    }
    var otherAudioReduction: MicrophoneProcessingOptions.Ducking {
        get { settings.otherAudioReduction }
        set { settings.otherAudioReduction = newValue }
    }

    var silenceStop: TimeInterval {
        get { settings.silenceStop }
        set { settings.silenceStop = newValue }
    }

    init(devices: any InputDeviceProviding, settings: DictationSettings, dictation: DictationCoordinator,
         microphoneTest: MicrophoneTestController? = nil) {
        self.devices = devices
        self.settings = settings
        self.dictation = dictation
        self.microphoneTest = microphoneTest
        deviceName = devices.defaultInputName()
    }

    /// Re-reads the device list when observation starts or a caller explicitly requests a refresh.
    func refreshDevice() { deviceName = devices.defaultInputName() }

    func observeDeviceChanges() async {
        let changes = devices.changes()
        refreshDevice()
        for await name in changes {
            guard !Task.isCancelled else { return }
            deviceName = name
        }
    }

    /// ST-04n "Open Sound Settings" — deep-links to the Sound pane.
    func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
