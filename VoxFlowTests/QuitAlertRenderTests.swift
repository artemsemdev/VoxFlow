import AppKit
import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("Quit alert render", .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] == "1"))
@MainActor struct QuitAlertRenderTests {
    @Test("renders the actual SYS-QUIT alert")
    func quitAlert() throws {
        _ = NSApplication.shared
        let alert = QuitCoordinator.makeAlert(QuitActivity(queueRunning: true, fileName: "interview-raw.m4a", progress: 0.72, dictation: .idle))
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        let view = try #require(alert.window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".superpowers/design/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("Files-141-quit-light.png"))
    }
}
