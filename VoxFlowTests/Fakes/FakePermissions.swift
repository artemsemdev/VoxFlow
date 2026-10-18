import Foundation
import Synchronization
@testable import VoxFlow

/// Scripted `PermissionChecking` for `PreflightBuilder` tests: counters prove each side effect
/// (a settings deep-link, a request, an accessibility prompt) fires exactly as often as expected.
final class FakePermissions: PermissionChecking, Sendable {
    private struct State {
        var microphone: PermissionState
        var requestResult: PermissionState
        var accessibility: Bool
        var requests = 0
        var openedMicrophoneSettings = 0
        var openedAccessibilitySettings = 0
        var prompted = 0
    }
    private let state: Mutex<State>

    init(microphone: PermissionState, requestResult: PermissionState, accessibility: Bool) {
        state = Mutex(State(microphone: microphone, requestResult: requestResult, accessibility: accessibility))
    }

    var requests: Int { state.withLock { $0.requests } }
    var openedMicrophoneSettings: Int { state.withLock { $0.openedMicrophoneSettings } }
    var openedAccessibilitySettings: Int { state.withLock { $0.openedAccessibilitySettings } }
    var prompted: Int { state.withLock { $0.prompted } }

    /// Settable after construction — `OnboardingViewModelTests` flips this mid-test to simulate the
    /// user granting Accessibility in System Settings while `openAccessibilitySettings()`'s poll is
    /// still running.
    var accessibility: Bool {
        get { state.withLock { $0.accessibility } }
        set { state.withLock { $0.accessibility = newValue } }
    }

    func microphone() -> PermissionState { state.withLock { $0.microphone } }

    /// Mirrors `SystemPermissions.requestMicrophone()`'s real-world effect: the OS grant/denial the
    /// user just made is reflected in the *next* `microphone()` read, not just in this call's return
    /// value — needed to express "notDetermined → granted, and a later `microphone()` reflects it".
    func requestMicrophone() async -> PermissionState {
        state.withLock { $0.requests += 1; $0.microphone = $0.requestResult; return $0.requestResult }
    }

    func accessibilityTrusted(prompt: Bool) -> Bool {
        state.withLock { s in
            if prompt { s.prompted += 1 }
            return s.accessibility
        }
    }

    func openMicrophoneSettings() { state.withLock { $0.openedMicrophoneSettings += 1 } }
    func openAccessibilitySettings() { state.withLock { $0.openedAccessibilitySettings += 1 } }
}
