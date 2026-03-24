namespace VoxFlow.Core.Models;

public sealed record ProgressUpdate(
    ProgressStage Stage,
    double PercentComplete,
    TimeSpan Elapsed,
    string? Message = null,
    string? CurrentLanguage = null,
    int? BatchFileIndex = null,
    int? BatchFileTotal = null);

public enum ProgressStage
{
    Validating,
    Converting,
    LoadingModel,
    Transcribing,
    Filtering,
    Writing,
    Complete,
    Failed
}
