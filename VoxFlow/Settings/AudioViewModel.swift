import AppKit
import Foundation

/// Settings › Audio (design ST-04, ST-04n). Thin: `deviceName`/`hasDevice` come from
/// `InputDeviceProviding` (re-read via `refreshDevice()`, since a device can appear/disappear while
/// the tab is open — ST-04n "auto-recovers when device appears"); `levels` mirrors the live
/// `DictationCoordinator` (flat while idle, per `DictationCoordinator.apply`); `silenceStop` is a
/// pass-through binding onto `DictationSettings`, which does its own 1…10 s clamping.
@Observable @MainActor
final class AudioViewModel {
    private let devices: any InputDeviceProviding
    private let settings: DictationSettings
    private let dictation: DictationCoordinator

    private(set) var deviceName: String?
    var hasDevice: Bool { deviceName != nil }
    var levels: [Float] { dictation.levels }

    var silenceStop: TimeInterval {
        get { settings.silenceStop }
        set { settings.silenceStop = newValue }
    }

    init(devices: any InputDeviceProviding, settings: DictationSettings, dictation: DictationCoordinator) {
        self.devices = devices
        self.settings = settings
        self.dictation = dictation
        deviceName = devices.defaultInputName()
    }

    /// Re-reads the device list — called from the view's `.task`/`.onAppear` so a mic plugged in
    /// while Settings is open clears the ST-04n banner without needing a relaunch.
    func refreshDevice() { deviceName = devices.defaultInputName() }

    /// ST-04n "Open Sound Settings" — deep-links to the Sound pane.
    func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
