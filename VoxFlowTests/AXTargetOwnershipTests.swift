import ApplicationServices
import Foundation
import Testing
@testable import VoxFlow

@Suite("AX target process ownership")
@MainActor
struct AXTargetOwnershipTests {
    @Test("the captured process must match even when another process reports the same app metadata")
    func processIdentity() {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Creating a process handle and reading its PID needs no Accessibility permission or UI.
        let target = AXTextTarget(AXUIElementCreateApplication(pid))
        let original = FrontmostApp(name: "Fixture", bundleID: "test.fixture", processID: pid)
        let other = FrontmostApp(name: "Fixture", bundleID: "test.fixture", processID: pid + 1)
        #expect(target.belongs(to: original))
        #expect(!target.belongs(to: other))
        #expect(!target.belongs(to: FrontmostApp(name: nil, bundleID: nil)))
    }
}
