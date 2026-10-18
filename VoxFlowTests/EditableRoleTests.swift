import Testing
@testable import VoxFlow

@Suite("EditableRole")
struct EditableRoleTests {
    @Test("text roles or a settable selection are editable; others are not", arguments: [
        ("AXTextField", false, true), ("AXTextArea", false, true), ("AXComboBox", false, true), ("AXSearchField", false, true),
        ("AXWebArea", true, true), ("AXList", false, false), ("AXButton", false, false), (nil as String?, false, false),
    ])
    func classify(role: String?, settable: Bool, expected: Bool) {
        #expect(EditableRole.isEditable(role: role, selectedTextSettable: settable) == expected)
    }
}
