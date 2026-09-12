import Foundation

/// A text edit relative to the range owned by the current live-insertion capture.
public enum LiveInsertionEdit: Sendable, Equatable {
    case none
    case append(text: String, atUTF16Offset: Int)
    case replaceTail(utf16Range: Range<Int>, with: String)
}

/// Separates planning an external write from committing it after that write succeeds.
public struct LiveInsertionPlanner: Sendable {
    public private(set) var committedText = ""
    private let identity = UUID()
    private var revision = UUID()

    public init() {}

    public func plan(for desiredText: String) -> Plan {
        if Self.isExactlyEqual(committedText, desiredText) {
            return Plan(edit: .none, baseline: committedText, desiredText: desiredText, owner: identity, revision: revision)
        }

        var committedIndex = committedText.startIndex
        var desiredIndex = desiredText.startIndex
        while committedIndex < committedText.endIndex, desiredIndex < desiredText.endIndex {
            let committedCharacter = String(committedText[committedIndex])
            let desiredCharacter = String(desiredText[desiredIndex])
            guard committedCharacter.utf16.elementsEqual(desiredCharacter.utf16) else { break }
            committedText.formIndex(after: &committedIndex)
            desiredText.formIndex(after: &desiredIndex)
        }

        let prefixUTF16Count = committedText[..<committedIndex].utf16.count
        let replacement = String(desiredText[desiredIndex...])
        let edit: LiveInsertionEdit
        if committedIndex == committedText.endIndex {
            edit = .append(text: replacement, atUTF16Offset: prefixUTF16Count)
        } else {
            edit = .replaceTail(
                utf16Range: prefixUTF16Count..<committedText.utf16.count,
                with: replacement
            )
        }
        return Plan(edit: edit, baseline: committedText, desiredText: desiredText, owner: identity, revision: revision)
    }

    @discardableResult
    public mutating func didApply(_ plan: Plan) -> Bool {
        guard plan.owner == identity, plan.revision == revision,
              Self.isExactlyEqual(committedText, plan.baseline) else { return false }
        committedText = plan.desiredText
        revision = UUID()
        return true
    }

    public mutating func reset() {
        committedText = ""
        revision = UUID() // even an empty capture invalidates every outstanding plan
    }

    public struct Plan: Sendable, Equatable {
        public let edit: LiveInsertionEdit
        fileprivate let baseline: String
        fileprivate let desiredText: String
        fileprivate let owner: UUID
        fileprivate let revision: UUID
    }

    private static func isExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
