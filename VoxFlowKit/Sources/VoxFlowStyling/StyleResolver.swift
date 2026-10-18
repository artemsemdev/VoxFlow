import VoxFlowCore

/// Resolves the effective `TextStyle` for a dictation (phase 4a plan, ruling 2):
/// a per-app override (keyed by bundle id) wins over the global default.
public enum StyleResolver: Sendable {
    public static func resolve(
        default defaultStyle: TextStyle,
        overrides: [String: TextStyle],
        bundleID: String?
    ) -> TextStyle {
        guard let bundleID, let override = overrides[bundleID] else {
            return defaultStyle
        }
        return override
    }
}
