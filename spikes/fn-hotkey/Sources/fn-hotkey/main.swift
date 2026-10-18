import AppKit
import ApplicationServices
import Carbon.HIToolbox

// kAXTrustedCheckOptionPrompt is a mutable CFStringRef global from the C SDK; Swift 6 strict
// concurrency flags any read of it as "shared mutable state". Its documented value is the
// literal string below (CFSTR("AXTrustedCheckOptionPrompt")), so use that directly.
let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
print("Accessibility trusted: \(trusted); Input Monitoring preflight: \(CGPreflightListenEventAccess())")
print("Secure input enabled now: \(IsSecureEventInputEnabled())")

var downAt: Date?
let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    let fn = event.modifierFlags.contains(.function)
    if fn, downAt == nil { downAt = Date(); print("fn DOWN  secureInput=\(IsSecureEventInputEnabled())") }
    if !fn, let start = downAt { print(String(format: "fn UP    held %.0f ms", Date().timeIntervalSince(start) * 1000)); downAt = nil }
}
print(monitor == nil ? "global monitor: nil (not trusted)" : "global monitor installed — press fn a few times")

DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    print("Inserting into the focused element of the frontmost app…")
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    let got = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
    guard got == .success, let element = focused else { print("no focused element: \(got.rawValue)"); return }
    let set = AXUIElementSetAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, "Hello from the VoxFlow spike. " as CFString)
    var app: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &app)
    print("AX set result: \(set.rawValue) (0 = success) role=\(app ?? "?" as CFTypeRef) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
}
RunLoop.main.run(until: Date().addingTimeInterval(20))
