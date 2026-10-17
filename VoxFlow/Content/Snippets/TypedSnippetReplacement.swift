import CoreGraphics
import Foundation
import VoxFlowStyling

@MainActor
enum TypedSnippetReplacement {
    // Ignore our own keyboard events so snippets cannot recursively expand their output.
    static let eventMarker: Int64 = 0x5646534E4950

    struct KeyboardEdit: Equatable {
        let deleteCount: Int
        let text: String
        let moveLeft: Int
    }

    static func apply(_ expansion: TypedSnippetExpansion, in value: String, selection: NSRange,
                      target: any AccessibilityTextTarget, isValid: () -> Bool,
                      sendKeys: (KeyboardEdit) -> Bool) -> Bool {
        guard isValid(), target.textValue == value, target.selectedRange == selection else { return false }
        if !target.supportsLiveInsertion {
            // Chromium's AX value is a virtual input buffer. Use it only to verify the trigger;
            // edit through normal input, never through its ineffective AX setters.
            guard let range = Range(expansion.range, in: value),
                  let caret = Range(selection, in: value)?.lowerBound, range.upperBound <= caret else { return false }
            let text = expansion.text + value[range.upperBound..<caret]
            let offset = NSRange(location: expansion.caretUTF16 - expansion.range.location, length: 0)
            guard let insertedCaret = Range(offset, in: text)?.lowerBound, isValid() else { return false }
            return sendKeys(KeyboardEdit(deleteCount: value[range.lowerBound..<caret].count,
                                         text: text, moveLeft: text[insertedCaret...].count))
        }
        guard target.setSelectedRange(expansion.range), isValid(),
              target.textValue == value, target.selectedRange == expansion.range else { return false }
        guard target.replaceSelectedText(expansion.text) else {
            if isValid(), target.textValue == value, target.selectedRange == expansion.range {
                _ = target.setSelectedRange(selection)
            }
            return false
        }
        let expected = (value as NSString).replacingCharacters(in: expansion.range, with: expansion.text)
        if isValid(), target.textValue == expected {
            _ = target.setSelectedRange(NSRange(location: expansion.caretUTF16, length: 0))
        }
        return true
    }

    static func deliver(_ edit: KeyboardEdit, to pid: pid_t, isValid: () -> Bool) -> Bool {
        var pairs: [(CGEvent, CGEvent)] = []
        func append(key: CGKeyCode, text: String? = nil) -> Bool {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                if let text {
                    let units = Array(text.utf16)
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                    }
                }
            }
            pairs.append((down, up))
            return true
        }
        // Allocate the entire edit before deleting anything. Unicode newlines never emit Return.
        for _ in 0..<edit.deleteCount { guard append(key: 51) else { return false } }
        for chunk in UnicodeTextDelivery.chunks(edit.text) { guard append(key: 0, text: chunk) else { return false } }
        for _ in 0..<edit.moveLeft { guard append(key: 123) else { return false } }
        for (down, up) in pairs {
            guard isValid() else { return false }
            down.postToPid(pid); up.postToPid(pid)
        }
        return true
    }
}
