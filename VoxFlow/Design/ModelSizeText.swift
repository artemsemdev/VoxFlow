import Foundation

enum ModelSizeText {
    /// Decimal model sizes used throughout the product: bytes at or above 1 GB use one decimal;
    /// smaller values truncate to the lower 10 MB bucket. The latter deliberately follows the
    /// canvas's explicit 487,601,967 B → 480 MB example rather than conventional nearest rounding.
    static func format(_ bytes: Int64) -> String {
        let nonnegativeBytes = max(0, bytes)
        if nonnegativeBytes >= 1_000_000_000 {
            return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"),
                          Double(nonnegativeBytes) / 1_000_000_000)
        }
        let megabytes = nonnegativeBytes / 1_000_000
        return "\((megabytes / 10) * 10) MB"
    }
}
