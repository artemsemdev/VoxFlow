namespace VoxFlow.Core.Models;

/// <summary>
/// The effective state of the managed speaker-labeling runtime, derived from the
/// runtime stamp and the current expected fingerprints. Drives whether setup,
/// repair, or nothing is needed.
/// </summary>
public enum SpeakerLabelingRuntimeState
{
    /// <summary>Stamp present and its fingerprints match the current ones.</summary>
    Ready,

    /// <summary>No stamp — the runtime has not been set up.</summary>
    SetupNeeded,

    /// <summary>Stamp is corrupt or from an unknown schema — re-setup to repair.</summary>
    RepairNeeded,

    /// <summary>Stamp present but requirements/sidecar fingerprints have changed.</summary>
    Stale,
}
