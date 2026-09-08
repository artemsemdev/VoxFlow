import VoxFlowCore

/// VoxFlowDictation — Flow Bar state machine: hotkey timing, silence stop, insertion policy.
/// Filled in from phase 1. The enum exists so the module has a compiled symbol and a
/// declared dependency on VoxFlowCore from day one.
public enum DictationModule {
    public static let name = "VoxFlowDictation"
    public static let coreVersion = VoxFlowVersion.string
}
