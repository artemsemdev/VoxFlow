import Foundation

/// File extensions VoxFlow accepts on drop (design MW-06 / MW-06x), lowercase. Single source of truth
/// for the decoder, the duration reader and the queue's drop gate.
public enum SupportedAudio {
    public static let extensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf", "mp4", "mov", "m4v",
    ]
    public static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}
