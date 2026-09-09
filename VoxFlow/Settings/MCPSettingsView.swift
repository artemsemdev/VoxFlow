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
            Button("Regenerate and copy") { mcp.confirmRegenerate() }
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
                Toggle("Enable MCP server", isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0 })).labelsHidden()
            }
            Text("Server arrives in a later release.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var endpointRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                Text(MCPViewModel.endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
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

    private func toolBinding(_ tool: MCPViewModel.Tool, settings: MCPSettings) -> Binding<Bool> {
        switch tool.id {
        case "transcribe_file": Binding(get: { settings.toolTranscribeFile }, set: { settings.toolTranscribeFile = $0 })
        case "dictate": Binding(get: { settings.toolDictate }, set: { settings.toolDictate = $0 })
        default: Binding(get: { settings.toolSearchHistory }, set: { settings.toolSearchHistory = $0 })
        }
    }

    // MARK: connected clients card

    private var connectedClientsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected clients").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(MCPViewModel.connectedClientsEmptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: ST-06r alert

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { mcp.alert != nil }, set: { isPresented in if !isPresented { mcp.dismissAlert() } })
    }
}
