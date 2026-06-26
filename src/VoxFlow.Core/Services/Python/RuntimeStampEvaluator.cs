using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Derives the <see cref="SpeakerLabelingRuntimeState"/> from a stamp read result
/// and the current expected fingerprints. Pure and deterministic; it is a fast
/// state hint, so a Ready result still does not replace live readiness checks.
/// </summary>
public static class RuntimeStampEvaluator
{
    public static SpeakerLabelingRuntimeState Evaluate(
        RuntimeStampReadResult read,
        string? expectedRequirementsHash,
        string? expectedSidecarHash)
    {
        System.ArgumentNullException.ThrowIfNull(read);

        switch (read.Status)
        {
            case RuntimeStampReadStatus.Missing:
                return SpeakerLabelingRuntimeState.SetupNeeded;

            case RuntimeStampReadStatus.Corrupt:
                return SpeakerLabelingRuntimeState.RepairNeeded;

            case RuntimeStampReadStatus.Ok:
                var stamp = read.Stamp!;
                if (stamp.SchemaVersion != SpeakerLabelingRuntimeStamp.CurrentSchemaVersion)
                {
                    // An unknown schema cannot be trusted; re-setup to repair.
                    return SpeakerLabelingRuntimeState.RepairNeeded;
                }

                var stale = stamp.RequirementsHash != expectedRequirementsHash
                            || stamp.SidecarHash != expectedSidecarHash;
                return stale ? SpeakerLabelingRuntimeState.Stale : SpeakerLabelingRuntimeState.Ready;

            default:
                return SpeakerLabelingRuntimeState.RepairNeeded;
        }
    }
}
