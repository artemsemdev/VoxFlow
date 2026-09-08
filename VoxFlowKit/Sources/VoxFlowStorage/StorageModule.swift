import VoxFlowCore

/// VoxFlowStorage — history, dictionary, snippets, styles on SQLite; encryption at rest.
/// Filled in from phase 1. The enum exists so the module has a compiled symbol and a
/// declared dependency on VoxFlowCore from day one.
public enum StorageModule {
    public static let name = "VoxFlowStorage"
    public static let coreVersion = VoxFlowVersion.string
}
