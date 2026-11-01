import AppKit
import Testing
@testable import VoxFlow

@Suite("Local shortcut events") @MainActor
struct InAppShortcutEventSourceTests {
    @Test func preservesKeyUpRepeatAndModifierSemantics() throws {
        for type in [NSEvent.EventType.keyDown, .keyUp, .flagsChanged] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero,
                modifierFlags: [.control, .shift], timestamp: 12, windowNumber: 0,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: true, keyCode: 0))
            let snapshot = try #require(InAppShortcutEventSource.snapshot(event))
            #expect(snapshot.keyCode == (type == .flagsChanged ? nil : 0))
            #expect(snapshot.flags == [.control, .shift])
            #expect(snapshot.timestamp == 12)
            #expect(snapshot.isRepeat == (type == .keyDown))
            #expect(snapshot.kind == (type == .flagsChanged ? .flagsChanged : type == .keyUp ? .keyUp : .keyDown))
        }
    }

    @Test func losingActivationEndsGestureAndStopRemovesObserver() {
        let source = InAppShortcutEventSource()
        var losses = 0
        source.start(handler: { _ in false }, onLoss: { losses += 1 })
        #expect(source.isRunning)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(losses == 1)
        source.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!source.isRunning && losses == 1)
    }
}
