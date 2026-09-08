import Foundation

/// Timestamp formatting shared by the writers and the UI.
public enum TimeCode {
    /// `HH:MM:SS,mmm` (SubRip).
    public static func srt(_ seconds: TimeInterval) -> String { hms(seconds, separator: ",") }
    /// `HH:MM:SS.mmm` (WebVTT and TXT brackets).
    public static func vtt(_ seconds: TimeInterval) -> String { hms(seconds, separator: ".") }
    public static func bracket(_ seconds: TimeInterval) -> String { vtt(seconds) }

    /// `M:SS` or `H:MM:SS`, seconds rounded to the nearest whole second.
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func hms(_ seconds: TimeInterval, separator: String) -> String {
        let totalMillis = Int((seconds * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis % 3_600_000) / 60_000
        let s = (totalMillis % 60_000) / 1000
        let ms = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }
}
