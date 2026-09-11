import Foundation

/// A slice of microphone audio in the internal format (16 kHz mono Float32) with its loudness.
public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    /// Root mean square of `samples`, 0 for an empty chunk. Drives the 14-bar waveform and silence detection.
    public var rms: Float

    public init(samples: [Float]) {
        self.samples = samples
        rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    public var duration: TimeInterval { Double(samples.count) / AudioSamples.sampleRate }
}

public enum MicrophoneError: Error, Equatable, Sendable {
    case accessDenied
    case noInputDevice
    /// The audio engine could not start or stopped; the other app, when known, is in the string.
    case engineFailed(String)
}

public enum MicrophoneEvent: Sendable, Equatable {
    case chunk(AudioChunk)
    /// The default input device changed (design ST-04n); nil when no device is left.
    case deviceChanged(name: String?)
}

/// Live microphone input. Capture runs until the consuming task is cancelled.
public protocol MicrophoneCapturing: Sendable {
    func start() -> AsyncThrowingStream<MicrophoneEvent, Error>
}

public enum InsertionResult: Sendable, Equatable {
    /// Text went into the focused field of `appName` (FB-04).
    case inserted(appName: String?)
    /// No editable field, or Accessibility unavailable: text is on the clipboard (FB-04b).
    case copiedToClipboard
}

/// Puts dictated text where the user was typing. Never throws: the clipboard is the fallback.
public protocol TextInserting: Sendable {
    /// `cursorOffset` counts Swift Characters from the start of the inserted text.
    func insert(_ text: String, cursorOffset: Int?) async -> InsertionResult
}

public extension TextInserting {
    func insert(_ text: String) async -> InsertionResult { await insert(text, cursorOffset: nil) }
}
