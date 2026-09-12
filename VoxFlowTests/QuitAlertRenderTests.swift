import AppKit
import SwiftUI
import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("Quit alert render", .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] == "1"))
@MainActor struct QuitAlertRenderTests {
    @Test("renders the actual SYS-QUIT alert")
    func quitAlert() async throws {
        _ = NSApplication.shared
        let alert = QuitCoordinator.makeAlert(QuitActivity(queueRunning: true, fileName: "interview-raw.m4a", progress: 0.72, dictation: .idle, etaText: "about 3 min left"))
        let host = NativeRenderHost(Color.clear, size: NSSize(width: 900, height: 600))
        await host.presentAlert(alert)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await host.captureAlert(to: directory.appendingPathComponent("Files-141-quit-light.png"))
        try await host.dismissAlert(alert)
    }
}
