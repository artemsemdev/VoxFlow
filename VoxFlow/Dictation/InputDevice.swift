import AVFoundation

/// The system's current default audio-input device (design ST-04 "Input device"). A protocol so
/// `AudioViewModel` can be tested against a fake instead of the real hardware/`AVCaptureDevice`.
protocol InputDeviceProviding: Sendable {
    /// The default input device's display name, or nil when nothing is available (ST-04n).
    func defaultInputName() -> String?
}

struct AVCaptureInputDeviceProvider: InputDeviceProviding {
    func defaultInputName() -> String? { AVCaptureDevice.default(for: .audio)?.localizedName }
}
