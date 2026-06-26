namespace VoxFlow.Core.Models;

/// <summary>Outcome of reading the speaker-labeling runtime stamp from disk.</summary>
public enum RuntimeStampReadStatus
{
    /// <summary>A valid stamp was read.</summary>
    Ok,

    /// <summary>No stamp file exists — the runtime has not been set up yet.</summary>
    Missing,

    /// <summary>A stamp file exists but could not be parsed — treat as repair-needed.</summary>
    Corrupt,
}

/// <summary>
/// The result of <see cref="VoxFlow.Core.Services.Python.IRuntimeStampStore.Read"/>:
/// a status plus the parsed <see cref="Stamp"/> when <see cref="Status"/> is
/// <see cref="RuntimeStampReadStatus.Ok"/> (otherwise null).
/// </summary>
public sealed record RuntimeStampReadResult(
    RuntimeStampReadStatus Status,
    SpeakerLabelingRuntimeStamp? Stamp);
