#nullable enable
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Provides structured startup validation results without console output.
/// </summary>
internal interface IStartupValidationFacade
{
    Task<StartupValidationResultDto> ValidateAsync(
        string? configurationPath = null,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Provides single-file and batch transcription as structured operations.
/// </summary>
internal interface ITranscriptionFacade
{
    Task<TranscribeFileResultDto> TranscribeFileAsync(
        TranscribeFileRequest request,
        CancellationToken cancellationToken = default);

    Task<BatchTranscribeResultDto> TranscribeBatchAsync(
        BatchTranscribeRequest request,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Provides model inspection without side effects.
/// </summary>
internal interface IModelInspectionFacade
{
    ModelInfoResultDto InspectModel(string? configurationPath = null);
}

/// <summary>
/// Provides language configuration information.
/// </summary>
internal interface ILanguageInfoFacade
{
    IReadOnlyList<SupportedLanguageDto> GetSupportedLanguages(string? configurationPath = null);
}

/// <summary>
/// Provides safe transcript file reading within allowed roots.
/// </summary>
internal interface ITranscriptReaderFacade
{
    Task<TranscriptReadResultDto> ReadTranscriptAsync(
        string path,
        int? maxCharacters = null,
        CancellationToken cancellationToken = default);
}
