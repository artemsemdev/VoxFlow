import SwiftUI

/// Settings › MCP Server (design ST-06, ST-06r): thin `ScrollView` wrapper around
/// `MCPSettingsBody` — split the same way `PrivacySettingsView`/`PrivacySettingsBody` are, so
/// `SettingsRenderTests` can render the content directly (`ImageRenderer` doesn't reliably capture
/// `ScrollView`).
struct MCPSettingsView: View {
    let mcp: MCPViewModel

    var body: some View {
        ScrollView { MCPSettingsBody(mcp: mcp) }
            .frame(maxWidth: .infinity)
            // Re-syncs with the real server every time this tab appears — it may already be
            // running (started by `AppDelegate` at launch) before Settings was ever opened, and
            // "Connected clients" should reflect the latest `mcp_clients` rows too.
            .task { await mcp.refresh() }
    }
}

struct MCPSettingsBody: View {
    let mcp: MCPViewModel

    var body: some View {
        let settings = mcp.settings
        VStack(alignment: .leading, spacing: 18) {
            serverCard(settings: settings)
            toolsCard(settings: settings)
            connectedClientsCard
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
        .alert(MCPViewModel.regenerateTitle, isPresented: alertIsPresented, presenting: mcp.alert) { _ in
            Button("Regenerate and copy") { Task { await mcp.confirmRegenerate() } }
            Button("Cancel", role: .cancel) { mcp.dismissAlert() }
        } message: { _ in
            Text(MCPViewModel.regenerateMessage)
        }
    }

    // MARK: server card

    private func serverCard(settings: MCPSettings) -> some View {
        VStack(spacing: 0) {
            enableRow(settings: settings)
            Divider().padding(.leading, 16)
            endpointRow
            Divider().padding(.leading, 16)
            tokenRow
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func enableRow(settings: MCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable MCP server")
                    Text("Lets local AI clients use VoxFlow as a tool. Listens on localhost only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable MCP server", isOn: enabledBinding).labelsHidden()
            }
            if let startFailure = mcp.startFailure {
                Text(startFailure)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { mcp.enabled }, set: { newValue in Task { await mcp.setEnabled(newValue) } })
    }

    private var endpointRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                Text(mcp.boundEndpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let portNote = mcp.portNote {
                    Text(portNote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Copy") { mcp.copyEndpoint() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tokenRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Access token")
                Text(mcp.maskedToken).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            // Review fix (Task 3 minor 1): `copyToken()` already existed and was already tested
            // (`MCPViewModelTests.copyToken`) but had no button calling it anywhere in the view.
            Button("Copy") { mcp.copyToken() }.buttonStyle(.bordered).controlSize(.small)
            Button("Regenerate") { mcp.requestRegenerate() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: tools card

    private func toolsCard(settings: MCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools exposed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12)
            VStack(spacing: 0) {
                ForEach(Array(MCPViewModel.tools.enumerated()), id: \.element.id) { index, tool in
                    toolRow(tool, settings: settings)
                    if index < MCPViewModel.tools.count - 1 { Divider().padding(.leading, 16) }
                }
            }
        }
        .padding(.bottom, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toolRow(_ tool: MCPViewModel.Tool, settings: MCPSettings) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name).fontWeight(.medium).font(.callout.monospaced())
                Text(tool.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(tool.name, isOn: toolBinding(tool, settings: settings)).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Review fix (Task 3 minor 2): matches against `MCPViewModel.tools`' own entries — the single
    /// source of truth for which id is which tool — instead of repeating `"transcribe_file"`/
    /// `"dictate"` as separate literals here, which could silently drift from `MCPViewModel.tools`.
    private func toolBinding(_ tool: MCPViewModel.Tool, settings: MCPSettings) -> Binding<Bool> {
        switch tool.id {
        case MCPViewModel.tools[0].id: Binding(get: { settings.toolTranscribeFile }, set: { settings.toolTranscribeFile = $0 })
        case MCPViewModel.tools[1].id: Binding(get: { settings.toolDictate }, set: { settings.toolDictate = $0 })
        default: Binding(get: { settings.toolSearchHistory }, set: { settings.toolSearchHistory = $0 })
        }
    }

    // MARK: connected clients card

    private var connectedClientsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected clients").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if mcp.clients.isEmpty {
                Text(MCPViewModel.connectedClientsEmptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(mcp.clients.enumerated()), id: \.element.id) { index, client in
                        clientRow(client)
                        if index < mcp.clients.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func clientRow(_ client: MCPViewModel.MCPClientRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).fontWeight(.medium)
                if !client.path.isEmpty {
                    Text(client.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(client.lastUsedText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke") { Task { await mcp.revoke(client.id) } }
                .buttonStyle(.bordered).controlSize(.small).tint(.red)
        }
        .padding(.vertical, 6)
    }

    // MARK: ST-06r alert

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { mcp.alert != nil }, set: { isPresented in if !isPresented { mcp.dismissAlert() } })
    }
}
