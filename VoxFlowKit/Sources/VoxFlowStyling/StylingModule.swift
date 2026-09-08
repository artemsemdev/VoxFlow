import VoxFlowCore

/// VoxFlowStyling — `TextStyler` implementations: rule-based now, llama.cpp later.
/// Filled in from phase 1. The enum exists so the module has a compiled symbol and a
/// declared dependency on VoxFlowCore from day one.
public enum StylingModule {
    public static let name = "VoxFlowStyling"
    public static let coreVersion = VoxFlowVersion.string
}
