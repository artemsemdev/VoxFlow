import AppKit
import ApplicationServices
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

/// Opt in with TEST_RUNNER_VOXFLOW_AX_LIVE_CHECK=1. Prepare a disposable TextEdit document
/// containing exactly "VOXFLOW-137-LIVE-CHECK\n", with its caret at the end, then activate it
/// after the readiness message. Uses the production default AX focus provider and live adapter.
/// No microphone, permission prompts, user clipboard writes or synthetic key events are used.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_AX_LIVE_CHECK"] == "1"),
       .timeLimit(.minutes(1)))
@MainActor
struct TextEditLiveInsertionTests {
    @Test("real external TextEdit accepts cumulative previews and one corrected final result")
    func cumulativeThenFinal() async throws {
        try #require(AXIsProcessTrusted(), "Existing Accessibility permission is required; no prompt will be issued.")
        let activation = LiveTextEditActivation()
        defer { activation.finish() }
        print("Live insertion fixture ready: activate the prepared VOXFLOW-137-LIVE-CHECK TextEdit document.")
        try await activation.wait()
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        try #require(app.bundleIdentifier == "com.apple.TextEdit")
        var value: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
            kAXFocusedUIElementAttribute as CFString, &value) == .success)
        let focused = try #require(value)
        try #require(CFGetTypeID(focused) == AXUIElementGetTypeID())
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        let target = AXTextTarget(element)
        let prefix = "VOXFLOW-137-LIVE-CHECK\n"
        let clipboard = FakePasteboard()
        // Intentionally omit focusTarget: production must discover the real external field.
        let inserter = AccessibilityTextInserter(permissions: LiveCheckPermissions(), pasteboard: clipboard)
        let validity = LiveCheckValidity()
        let context = LiveInsertionContext { validity.isActive }
        defer { validity.cancel() }

        try await withTaskCancellationHandler {
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix, caret: prefix.utf16.count)
            await inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix, caret: prefix.utf16.count)
            await inserter.beginLiveInsertion(context)
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix, caret: prefix.utf16.count)
            await inserter.updateLiveInsertion("hello", context: context)
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix + "hello", caret: prefix.utf16.count + 5)
            await inserter.updateLiveInsertion("hello world", context: context)
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix + "hello world", caret: prefix.utf16.count + 11)
            let result = await inserter.finishLiveInsertion("Hello, world!", cursorOffset: 6, context: context)
            try #require(result == .inserted(appName: "TextEdit"))
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix + "Hello, world!", caret: prefix.utf16.count + 6)
            #expect(await inserter.finishLiveInsertion("Hello, world!", cursorOffset: nil, context: context) == nil)
            try checkScratch(target, element: element, pid: app.processIdentifier,
                             text: prefix + "Hello, world!", caret: prefix.utf16.count + 6)
            #expect(clipboard.strings.isEmpty)
        } onCancel: {
            validity.cancel()
        }
    }

    /// Check only booleans so a failure cannot print an unrelated document's contents.
    /// The production adapter repeats focus/text/range ownership checks at every actual write.
    private func checkScratch(_ target: AXTextTarget, element: AXUIElement, pid: pid_t,
                              text: String, caret: Int) throws {
        try Task.checkCancellation()
        try #require(AXIsProcessTrusted())
        let frontmost = NSWorkspace.shared.frontmostApplication
        try #require(frontmost?.bundleIdentifier == "com.apple.TextEdit" && frontmost?.processIdentifier == pid)
        var actualPID: pid_t = 0
        try #require(AXUIElementGetPid(element, &actualPID) == .success && actualPID == pid)
        let current = try #require(AXTextTarget.focused())
        try #require(target.isSameTarget(as: current))
        let exactScratchContents = target.textValue == text
        try #require(exactScratchContents, "Only the exact prepared fixture contents may be changed.")
        let exactScratchSelection = target.selectedRange == NSRange(location: caret, length: 0)
        try #require(exactScratchSelection, "The fixture caret must remain at its expected position.")
        try #require(target.isEditable)
    }
}

/// Reads actual AX trust but refuses to prompt even if the production capture requests it.
private struct LiveCheckPermissions: PermissionChecking {
    func accessibilityTrusted(prompt: Bool) -> Bool { AXIsProcessTrusted() }
    func microphone() -> PermissionState { .denied }
    func requestMicrophone() async -> PermissionState { .denied }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
}

private final class LiveCheckValidity: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func cancel() { active.withLock { $0 = false } }
}

@MainActor
private final class LiveTextEditActivation: NSObject {
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
        for await _ in events { try Task.checkCancellation(); return }
        throw CancellationError()
    }

    func finish() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        continuation.finish()
    }
}
