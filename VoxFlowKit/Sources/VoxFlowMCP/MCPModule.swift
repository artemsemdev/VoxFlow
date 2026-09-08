import VoxFlowCore

/// VoxFlowMCP — loopback HTTP MCP server, access token, client approval, path policy.
/// Filled in from phase 1. The enum exists so the module has a compiled symbol and a
/// declared dependency on VoxFlowCore from day one.
public enum MCPModule {
    public static let name = "VoxFlowMCP"
    public static let coreVersion = VoxFlowVersion.string
}
