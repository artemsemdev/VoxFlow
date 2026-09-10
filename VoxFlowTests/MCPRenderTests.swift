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
/// Same `ImageRenderer` limitation `SettingsRenderTests` documents: `Toggle` rasterizes as a plain
/// yellow "unavailable cursor" glyph instead of its real appearance — everything else (labels,
/// buttons, the connected-clients rows) is representative.
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
        try store.recordSighting(name: "Claude Desktop", path: "/Applications/Claude.app", now: now.addingTimeInterval(-30))
        let server = FakeMCPServer(store: store)
        server.portToReturn = 7331
        let vm = MCPViewModel(settings: settings, pasteboard: FakePasteboard(), server: server, clientStoreProvider: server, now: { now })
        await vm.setEnabled(true)
        await vm.refreshClients()
        try Self.render(MCPSettingsBody(mcp: vm), name: "settings", to: directory)

        // ST-06a (canvas page 5): exact canvas example — "Cursor", pid 4812, transcribe_file + dictate.
        let approvalContent = MCPApprovalContentView(
            title: MCPApprovalCopy.title(name: "Cursor"),
            message: MCPApprovalCopy.body(tools: ["transcribe_file", "dictate"]),
            processLine: MCPApprovalCopy.processLine(name: "Cursor", pid: 4812),
            canPersist: true,
            onAlwaysAllow: {}, onAllowOnce: {}, onDeny: {})
        try Self.render(approvalContent.frame(width: 340), name: "approval", to: directory)

        // ST-06r (canvas page 6, moved here from `SettingsRenderTests` — Task 3): `.alert()` itself
        // is a native window `ImageRenderer` can't capture, so this reproduces the card layout the
        // MW-06c/SYS-DISK alerts use on canvas page 5 (icon, centered title, centered message,
        // stacked full-width buttons) with the ruling-4-extended copy.
        try Self.render(MCPRegenerateAlertPreview(), name: "regenerate", to: directory)
    }

    private static func render(_ view: some View, name: String, to directory: URL) throws {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("MCP-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
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
