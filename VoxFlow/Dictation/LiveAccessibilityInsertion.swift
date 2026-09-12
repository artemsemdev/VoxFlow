import Foundation
import VoxFlowCore
import VoxFlowDictation

/// AX operations run without suspension on the main actor. Any observed focus, text or selection
/// change permanently blocks this capture. Cancel preserves every edit already committed.
@MainActor
final class LiveAccessibilityInsertion {
    let context: LiveInsertionContext
    private let target: (any AccessibilityTextTarget)?
    private let appName: String?
    private let permissions: any PermissionChecking
    private let pasteboard: any Pasteboard
    private let focusTarget: @MainActor () -> (any AccessibilityTextTarget)?
    private var planner = LiveInsertionPlanner()
    private var expectedText: String?
    private var expectedSelection: NSRange?
    private let initialSelection: NSRange?
    private var hasWritten = false
    private var blocked: CopyReason?

    init(context: LiveInsertionContext, target: (any AccessibilityTextTarget)?, appName: String?,
         initialText: String?, initialSelection: NSRange?,
         permissions: any PermissionChecking, pasteboard: any Pasteboard,
         focusTarget: @escaping @MainActor () -> (any AccessibilityTextTarget)?) {
        self.context = context; self.target = target; self.appName = appName
        self.permissions = permissions; self.pasteboard = pasteboard; self.focusTarget = focusTarget
        expectedText = initialText; expectedSelection = initialSelection
        self.initialSelection = initialSelection
    }

    private func ownsTarget() -> Bool {
        guard context.isActive, blocked == nil else { return false }
        guard permissions.accessibilityTrusted(prompt: false) else { blocked = .accessibilityDenied; return false }
        guard let target, target.isEditable else { blocked = .noTextField; return false }
        guard let focused = focusTarget(), target.isSameTarget(as: focused),
              let expectedText, let actual = target.textValue,
              actual.utf16.elementsEqual(expectedText.utf16), let expectedSelection,
              target.selectedRange == expectedSelection else { blocked = .insertionFailed; return false }
        return context.isActive
    }

    func update(_ text: String) {
        guard ownsTarget(), let target, let expectedText, let initialSelection else { return }
        let plan = planner.plan(for: text)
        let relative: NSRange
        let replacement: String
        switch plan.edit {
        case .none: return
        case .append(let suffix, let offset):
            relative = NSRange(location: offset, length: hasWritten ? 0 : initialSelection.length)
            replacement = suffix
        case .replaceTail(let range, let suffix):
            relative = NSRange(location: range.lowerBound, length: range.count)
            replacement = suffix
        }
        let (start, overflow) = initialSelection.location.addingReportingOverflow(relative.location)
        guard !overflow, start >= 0, start <= expectedText.utf16.count,
              relative.length >= 0, relative.length <= expectedText.utf16.count - start else {
            blocked = .insertionFailed; return
        }
        let range = NSRange(location: start, length: relative.length)
        if target.selectedRange != range {
            guard context.isActive, target.setSelectedRange(range) else { blocked = .insertionFailed; return }
            expectedSelection = range
        }
        // Selection changes can trigger target-side editing. Recheck immediately before writing.
        guard ownsTarget(), context.isActive, target.replaceSelectedText(replacement) else {
            if context.isActive { blocked = .insertionFailed }
            return
        }
        self.expectedText = (expectedText as NSString).replacingCharacters(in: range, with: replacement)
        expectedSelection = NSRange(location: start + replacement.utf16.count, length: 0)
        hasWritten = true
        _ = planner.didApply(plan)
    }

    func finish(_ text: String, cursorOffset: Int?) -> InsertionResult? {
        guard context.isActive else { return nil }
        update(text)
        guard context.isActive else { return nil }
        guard ownsTarget() else {
            guard context.isActive else { return nil }
            pasteboard.setString(text)
            return .copiedToClipboard(reason: blocked ?? .insertionFailed)
        }
        if let offset = cursorOffset, offset >= 0, offset <= text.count,
           let start = initialSelection?.location, context.isActive {
            _ = target?.setSelectedRange(NSRange(location: start + text.prefix(offset).utf16.count, length: 0))
        }
        return .inserted(appName: appName)
    }
}
