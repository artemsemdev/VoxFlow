import Foundation

public enum HotkeyMode: String, Sendable, Codable, CaseIterable, Equatable {
    case pushToTalk, handsFree
}

/// Timings from the design (3d "Hotkey timing", "Listening", "Processing", "Auto-dismiss").
public struct FlowBarConfig: Sendable, Equatable {
    public static let silenceStopRange: ClosedRange<TimeInterval> = 1...10

    public var holdThreshold: TimeInterval = 0.25
    public var doubleTapWindow: TimeInterval = 0.35
    public private(set) var silenceStop: TimeInterval = 3
    public var maxDuration: TimeInterval = 900
    public var takingLongerAfter: TimeInterval = 8
    public var processingTimeout: TimeInterval = 20
    public var dismissInserted: TimeInterval = 1.5
    public var dismissCopied: TimeInterval = 2.5
    public var dismissDiscarded: TimeInterval = 0.8
    public var dismissError: TimeInterval = 4
    /// RMS at or above this counts as voice for the hands-free silence timer.
    public var voiceRMS: Float = DictationDefaults.voiceRMS
    /// Cap on `.loadModel` while `.loadingModel`: no exit otherwise if the load stalls (I1).
    public var modelLoadTimeout: TimeInterval = 30

    public init(silenceStop: TimeInterval = 3) {
        self.silenceStop = min(max(silenceStop, Self.silenceStopRange.lowerBound), Self.silenceStopRange.upperBound)
    }
}
