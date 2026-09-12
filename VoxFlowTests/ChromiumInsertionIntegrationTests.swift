import AppKit
import ApplicationServices
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

/// Opt in with TEST_RUNNER_VOXFLOW_AX_EDITOR_CHECK=1. Open the initially empty disposable
/// /tmp/voxflow-production-editor-check.txt in VS Code, then activate its editor at readiness.
/// No microphone, permission prompt, real clipboard write or unrelated document save is used.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_AX_EDITOR_CHECK"] == "1"),
       .timeLimit(.minutes(1)))
@MainActor
struct ChromiumInsertionIntegrationTests {
    private let file = URL(fileURLWithPath: "/tmp/voxflow-production-editor-check.txt")
    private let expected = "Проверка VoxFlow: русский текст и эмодзи 👋🏽.\nВторая строка сохраняется без потерь.\n"

    @Test("production Chromium insertion persists Unicode final text without preview writes")
    func finalTextPersists() async throws {
        try #require(AXIsProcessTrusted(), "Existing Accessibility permission is required; never prompt.")
        let activation = EditorActivation()
        defer { activation.finish() }
        print("VS Code production insertion fixture ready: activate voxflow-production-editor-check.txt.")
        try await activation.wait()
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        try #require(app.bundleIdentifier == "com.microsoft.VSCode")
        let target = try #require(AXTextTarget.focused())
        let pid = app.processIdentifier
        let clipboard = FakePasteboard()
        let inserter = AccessibilityTextInserter(permissions: EditorPermissions(), pasteboard: clipboard)
        let validity = EditorValidity()
        let context = LiveInsertionContext { validity.isActive }
        defer { validity.cancel() }
        try await withTaskCancellationHandler {
            try checkEmpty(target, pid: pid)
            await inserter.captureFocus(app: FrontmostApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"))
            try checkEmpty(target, pid: pid)
            await inserter.beginLiveInsertion(context)
            await inserter.updateLiveInsertion("Проверка", context: context)
            try checkEmpty(target, pid: pid)
            await inserter.updateLiveInsertion("Проверка VoxFlow: русский текст", context: context)
            try checkEmpty(target, pid: pid)
            let result = await inserter.finishLiveInsertion(expected, cursorOffset: nil, context: context)
            try #require(result == .inserted(appName: "Visual Studio Code"))
            try #require(clipboard.strings.isEmpty)
            // Save only while the same captured editor in the exact disposable window owns focus.
            try checkEditor(target, pid: pid)
            let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true))
            let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: false))
            down.flags = .maskCommand; up.flags = .maskCommand
            try checkEditor(target, pid: pid)
            down.postToPid(pid); up.postToPid(pid)
            let deadline = ContinuousClock.now + .seconds(5)
            var persistedExactly = false
            repeat {
                try Task.checkCancellation()
                persistedExactly = try Data(contentsOf: file) == Data(expected.utf8)
                if persistedExactly { break }
                // Real external editor/file I/O has no in-process completion callback.
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            print("VS Code production insertion persisted exact Unicode: \(persistedExactly)")
            #expect(persistedExactly, "Only the disposable fixture file is inspected.")
            #expect(clipboard.strings.isEmpty)
        } onCancel: { validity.cancel() }
    }

    private func checkEmpty(_ target: AXTextTarget, pid: pid_t) throws {
        try checkEditor(target, pid: pid)
        let resources = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try #require(resources.isRegularFile == true && resources.isSymbolicLink != true)
        let fileIsEmpty = try Data(contentsOf: file).isEmpty
        let editorIsEmpty = target.textValue == ""
        let caretIsAtStart = target.selectedRange == NSRange(location: 0, length: 0)
        try #require(fileIsEmpty && editorIsEmpty && caretIsAtStart,
                     "The exact empty disposable file and editor are required before any write.")
    }

    private func checkEditor(_ target: AXTextTarget, pid: pid_t) throws {
        try Task.checkCancellation()
        try #require(AXIsProcessTrusted())
        let app = NSWorkspace.shared.frontmostApplication
        try #require(app?.bundleIdentifier == "com.microsoft.VSCode" && app?.processIdentifier == pid)
        let current = try #require(AXTextTarget.focused())
        try #require(target.isSameTarget(as: current))
        let application = AXUIElementCreateApplication(pid)
        let window = try #require(elementAttribute(application, kAXFocusedWindowAttribute))
        let ownsFixtureWindow = (attribute(window, kAXTitleAttribute) as? String)?.contains(file.lastPathComponent) == true
        try #require(ownsFixtureWindow, "Never send keys to an unrelated document.")
        let focused = try #require(elementAttribute(application, kAXFocusedUIElementAttribute))
        let isEditor = (attribute(focused, kAXRoleAttribute) as? String) == kAXTextAreaRole &&
            (attribute(focused, kAXDescriptionAttribute) as? String)?.lowercased().contains("editor") == true
        try #require(isEditor && target.isEditable)
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

private struct EditorPermissions: PermissionChecking {
    func accessibilityTrusted(prompt: Bool) -> Bool { AXIsProcessTrusted() }
    func microphone() -> PermissionState { .denied }
    func requestMicrophone() async -> PermissionState { .denied }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
}

private final class EditorValidity: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func cancel() { active.withLock { $0 = false } }
}

@MainActor
private final class EditorActivation: NSObject {
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
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.VSCode" else { return }
        continuation.yield(()); continuation.finish()
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
