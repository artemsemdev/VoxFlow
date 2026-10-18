import AppKit
import ApplicationServices
import Testing
import VoxFlowCore
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

/// Explicit interactive check. In a new TextEdit document type "VOXFLOW-161-CURSOR-CHECK" and a
/// newline, then activate it after starting this fixture with TEST_RUNNER_VOXFLOW_AX_CARET_CHECK=1.
/// Default unit tests never access a live Accessibility target. No permission prompts are issued.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_AX_CARET_CHECK"] == "1"),
       .timeLimit(.minutes(1)))
@MainActor
struct SnippetCaretIntegrationTests {
    @Test("the signature snippet leaves the real TextEdit caret between Best and Artem")
    func textEditCaret() async throws {
        try #require(AXIsProcessTrusted(), "This explicit integration check needs existing Accessibility permission.")
        let activation = TextEditActivation()
        defer { activation.finish() }
        print("Snippet caret fixture ready: activate the prepared TextEdit scratch document.")
        try await activation.wait()
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        try #require(app.bundleIdentifier == "com.apple.TextEdit")
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &value)
        try #require(status == .success)
        let focused = try #require(value)
        try #require(CFGetTypeID(focused) == AXUIElementGetTypeID())
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        var pid: pid_t = 0
        try #require(AXUIElementGetPid(element, &pid) == .success)
        try #require(pid == app.processIdentifier)
        let prefix = "VOXFLOW-161-CURSOR-CHECK\n"
        // Guard the scratch document before touching it, without logging unrelated document text.
        let isScratchDocument = Self.text(in: element) == prefix
        try #require(isScratchDocument, "Only the prepared disposable scratch document may be changed.")
        let target = ScratchTextTarget(element: element, pid: pid, prefix: prefix)
        try #require(target.selectedRange == NSRange(location: prefix.utf16.count, length: 0))
        let clipboard = FakePasteboard()
        let inserter = AccessibilityTextInserter(
            permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
            pasteboard: clipboard, focusTarget: { target })
        let expander = SnippetExpander(snippets: [.init(trigger: "/sig", body: "Best,\n{cursor}\nArtem")],
            sayPrefix: false, context: (Date(), nil, "TextEdit", "com.apple.TextEdit"))
        let result = expander.expand("/sig")
        await inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
        try Task.checkCancellation()
        try #require(await inserter.insert(result.text, cursorOffset: result.cursorOffset) == .inserted(appName: "TextEdit"))
        let expectedTextInserted = Self.text(in: element) == prefix + "Best,\n\nArtem"
        #expect(expectedTextInserted)
        #expect(target.selectedRange == NSRange(location: prefix.utf16.count + 6, length: 0))
        #expect(clipboard.strings.isEmpty)
    }

    fileprivate static func text(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

@MainActor
private final class TextEditActivation: NSObject {
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        activated()
    }

    @objc private func activated() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else { return }
        continuation.yield(())
        continuation.finish()
    }

    func wait() async throws {
        for await _ in events {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }

    func finish() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        continuation.finish()
    }
}

/// Revalidate immediately at the write, after the inserter's actor hops. A changed document is
/// refused and falls back only to the fixture's fake clipboard.
@MainActor
private final class ScratchTextTarget: AccessibilityTextTarget {
    let element: AXUIElement
    let pid: pid_t
    let prefix: String
    private let target: AXTextTarget
    private var insertedText: String?

    init(element: AXUIElement, pid: pid_t, prefix: String) {
        self.element = element; self.pid = pid; self.prefix = prefix
        target = AXTextTarget(element)
    }
    var isEditable: Bool { target.isEditable }
    var selectedRange: NSRange? { target.selectedRange }
    private func hasText(_ text: String) -> Bool {
        var currentPID: pid_t = 0
        return !Task.isCancelled && AXUIElementGetPid(element, &currentPID) == .success
            && currentPID == pid && SnippetCaretIntegrationTests.text(in: element) == text
    }
    func replaceSelectedText(_ text: String) -> Bool {
        guard hasText(prefix), selectedRange == NSRange(location: prefix.utf16.count, length: 0),
              target.replaceSelectedText(text) else { return false }
        insertedText = prefix + text
        return true
    }
    func setSelectedRange(_ range: NSRange) -> Bool {
        guard let insertedText, hasText(insertedText) else { return false }
        return target.setSelectedRange(range)
    }
}
