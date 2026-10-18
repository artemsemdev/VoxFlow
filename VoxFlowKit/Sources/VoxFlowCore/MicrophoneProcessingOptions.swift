import Foundation

/// Apple's voice processing couples noise suppression with at least minimum output ducking.
public struct MicrophoneProcessingOptions: Sendable, Equatable {
    public enum Ducking: String, Sendable, CaseIterable {
        case minimum, standard, maximum
        public var title: String { rawValue.capitalized }
    }
    public var noiseSuppression: Bool
    public var ducking: Ducking
    public init(noiseSuppression: Bool = false, ducking: Ducking = .minimum) {
        self.noiseSuppression = noiseSuppression; self.ducking = ducking
    }
}
