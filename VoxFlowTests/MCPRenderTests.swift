import AppKit
import SwiftUI
import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Design-fidelity renders (Task 4 Step 4) — gated behind `VOXFLOW_RENDER` so normal test runs
/// never touch disk. Run with
/// `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/MCPRenderTests`
/// (see `OnboardingRenderTests` for why the `TEST_RUNNER_` prefix is needed), then compare the PNGs
/// in `.superpowers/design/renders/` against `canvas.pdf` page 6 (ST-06, the Settings › MCP Server
/// tab) and page 5 (ST-06a, the client-approval panel).
///
/// Supersedes the "mcp"/"mcp-regenerate" cases that used to live in `SettingsRenderTests` (Task 3):
/// this is now the one file that owns MCP design-fidelity, since `MCPSettingsBody` needs a real
/// `MCPServerControlling`/`MCPClientStoreProviding` pair to render post-Task-4's state at all.
///
/// Native hosting captures actual controls while preserving the original fixture viewports.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct MCPRenderTests {
    @Test("renders the MCP Settings page (enabled, with connected clients) and the ST-06a approval panel")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // ST-06 (canvas page 6): enabled, bound endpoint, two connected clients (one approved via
        // "Always allow", one merely sighted) so the "Connected clients" card's real row layout —
        // not just its empty state — is part of the comparison.
        let settings = MCPSettings(store: InMemoryKeyValueStore(), token: FakeTokenStore())
        _ = settings.token   // force generation so "Access token" shows its masked form
        let store = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.approve(name: "Cursor", path: "/Applications/Cursor.app", now: now.addingTimeInterval(-90))
        try store.approve(name: "Claude Desktop", path: "/Applications/Claude.app", now: now.addingTimeInterval(-30))
        let server = FakeMCPServer(store: store)
        server.portToReturn = 7331
        let vm = MCPViewModel(settings: settings, pasteboard: FakePasteboard(), server: server, clientStoreProvider: server,
                              approvalObserver: FakeApprovalObserver(), now: { now })
        await vm.setEnabled(true)
        await vm.refreshClients()
        try await Self.render(MCPSettingsBody(mcp: vm), name: "settings", size: NSSize(width: 423.5, height: 602), to: directory)

        // ST-06a (canvas page 5): exact canvas example — "Cursor", pid 4812, transcribe_file + dictate.
        let approvalContent = MCPApprovalContentView(
            title: MCPApprovalCopy.title(name: "Cursor"),
            message: MCPApprovalCopy.body(tools: ["transcribe_file", "dictate"]),
            processLine: MCPApprovalCopy.processLine(name: "Cursor", pid: 4812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            buttons: MCPApprovalButtons.offered(canPersist: true),
            onDecision: { _ in })
        try await Self.render(approvalContent.frame(width: 340), name: "approval", size: NSSize(width: 340, height: 301), to: directory)

        // ST-06r (canvas page 6, moved here from `SettingsRenderTests` — Task 3): `.alert()` itself
        // is a native window `ImageRenderer` can't capture, so this reproduces the card layout the
        // MW-06c/SYS-DISK alerts use on canvas page 5 (icon, centered title, centered message,
        // stacked full-width buttons) with the ruling-4-extended copy.
        try await Self.render(MCPRegenerateAlertPreview(), name: "regenerate", size: NSSize(width: 400, height: 374), to: directory)
    }

    private static func render(_ view: some View, name: String, size: NSSize, to directory: URL) async throws {
        let host = NativeRenderHost(view, size: size)
        try await host.captureSettled(to: directory.appendingPathComponent("MCP-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }
}

/// A same-style stand-in for the ST-06r "Regenerate the access token?" confirmation — `.alert()`
/// itself is a native window `ImageRenderer` can't capture, so this reproduces the card layout the
/// MW-06c/SYS-DISK alerts use on canvas page 5 (icon, centered title, centered message, stacked
/// full-width buttons) with ST-06r's copy for a same-page visual comparison against canvas page 6.
private struct MCPRegenerateAlertPreview: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(MCPViewModel.regenerateTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(MCPViewModel.regenerateMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Text("Regenerate and copy")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(.white)
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(40)
    }
}
