import AppKit
import ApplicationServices
import AVFoundation

enum PermissionState: Sendable, Equatable { case notDetermined, granted, denied }

protocol PermissionChecking: Sendable {
    func microphone() -> PermissionState
    func requestMicrophone() async -> PermissionState
    func accessibilityTrusted(prompt: Bool) -> Bool
    func openMicrophoneSettings()
    func openAccessibilitySettings()
}

struct SystemPermissions: PermissionChecking {
    func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestMicrophone() async -> PermissionState { await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied }
    func accessibilityTrusted(prompt: Bool) -> Bool {
        #if APP_STORE
        false
        #else
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        #endif
    }
    func openMicrophoneSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    func openAccessibilitySettings() {
        #if !APP_STORE
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #endif
    }
    private func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }
}
