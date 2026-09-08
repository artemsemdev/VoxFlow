import Foundation

/// Shared defaults so the HUD's silence-stop decision (`FlowBarConfig.voiceRMS`) and the window
/// cut point (`WindowPlanner.voiceRMS`) can't silently drift apart — see I4.
public enum DictationDefaults {
    /// RMS at or above this counts as voice.
    public static let voiceRMS: Float = 0.01
}
