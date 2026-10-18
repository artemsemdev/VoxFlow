import AppKit

enum FnTransition: Equatable { case down, up }

/// Turns modifier-flag snapshots into fn press/release edges (design 3d "Hotkey timing" feeds the machine).
struct FnKeyDecoder {
    private var isDown = false
    mutating func decode(flags: NSEvent.ModifierFlags) -> FnTransition? {
        let now = flags.contains(.function)
        defer { isDown = now }
        if now && !isDown { return .down }
        if !now && isDown { return .up }
        return nil
    }
}
