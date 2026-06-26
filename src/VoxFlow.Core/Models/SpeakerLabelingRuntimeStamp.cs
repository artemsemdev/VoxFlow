using System;

namespace VoxFlow.Core.Models;

/// <summary>
/// A small, versioned record of the last known-good speaker-labeling runtime so
/// setup/preflight can tell ready / stale / repair-needed apart without
/// re-discovering everything every run. It is a fast state hint, not the source
/// of truth for live conditions.
/// </summary>
/// <remarks>
/// The field set deliberately excludes anything sensitive: no Hugging Face token
/// or other secret, no audio path, and no transcript content. It records only
/// runtime fingerprints (Python, requirements, sidecar, model id) and when they
/// were last validated. The file is safe to delete to force a clean re-setup.
/// </remarks>
public sealed record SpeakerLabelingRuntimeStamp(
    int SchemaVersion,
    string RuntimeId,
    string? PythonExecutable,
    string? PythonVersion,
    string? RequirementsHash,
    string? SidecarHash,
    string? ModelId,
    string? ModelCacheState,
    DateTimeOffset ValidatedAt)
{
    /// <summary>Current on-disk schema. Bump when the shape changes incompatibly.</summary>
    public const int CurrentSchemaVersion = 1;
}
