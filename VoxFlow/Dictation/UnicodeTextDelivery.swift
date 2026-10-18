import CoreGraphics
import Foundation

/// Chromium editors may expose a writable AXSelectedText setter that does not edit their buffer.
/// Deliver final text through normal Unicode keyboard input, without using the user's clipboard.
@MainActor
enum UnicodeTextDelivery {
    typealias Pair = @MainActor () -> Void
    typealias PairFactory = @MainActor (String) -> Pair?

    nonisolated static func chunks(_ text: String) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = [], start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]),
               (0xDC00...0xDFFF).contains(units[end]) { end -= 1 }
            result.append(String(decoding: units[start..<end], as: UTF16.self))
            start = end
        }
        return result
    }

    static func deliver(_ text: String, to pid: pid_t, isValid: () -> Bool) -> Bool {
        send(text, isValid: isValid) { chunk in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return nil }
            let units = Array(chunk.utf16)
            down.flags = []; up.flags = []
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            // No Return key is generated, including when the Unicode text contains a newline.
            return { down.postToPid(pid); up.postToPid(pid) }
        }
    }

    /// A failed allocation produces no partial delivery. Recheck ownership before every pair;
    /// down/up stay together so cancellation cannot leave an injected key held down.
    static func send(_ text: String, isValid: () -> Bool, makePair: PairFactory) -> Bool {
        guard isValid() else { return false }
        var pairs: [Pair] = []
        for chunk in chunks(text) {
            guard let pair = makePair(chunk) else { return false }
            pairs.append(pair)
        }
        for pair in pairs {
            guard isValid() else { return false }
            pair()
        }
        return true
    }
}

enum ChromiumAppFrameworks {
    private static let names = ["Electron Framework.framework", "Google Chrome Framework.framework",
        "Chromium Framework.framework", "Brave Browser Framework.framework", "Microsoft Edge Framework.framework"]

    /// Inspect bundle structure only; never read application contents or editor documents.
    static func containsSupportedFramework(in app: URL) -> Bool {
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return names.contains { name in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(name).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
