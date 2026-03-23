#nullable enable
using System;
using System.Collections.Generic;

/// <summary>
/// Structured result of startup validation, suitable for both CLI and MCP consumption.
/// </summary>
internal sealed record StartupValidationResultDto(
    string Outcome,
    bool CanStart,
    bool HasWarnings,
    string ResolvedConfigurationPath,
    IReadOnlyList<StartupCheckDto> Checks);

/// <summary>
/// One check from startup validation.
/// </summary>
internal sealed record StartupCheckDto(
    string Name,
    string Status,
    string Details);

/// <summary>
/// Request to transcribe a single audio file.
/// </summary>
internal sealed record TranscribeFileRequest(
    string InputPath,
    string? ResultFilePath = null,
    string? ConfigurationPath = null,
    IReadOnlyList<string>? ForceLanguages = null,
    bool OverwriteExistingResult = true);

/// <summary>
/// Structured result of a single-file transcription.
/// </summary>
internal sealed record TranscribeFileResultDto(
    bool Success,
    string? DetectedLanguage,
    string? ResultFilePath,
    int AcceptedSegmentCount,
    int SkippedSegmentCount,
    TimeSpan Duration,
    IReadOnlyList<string> Warnings,
    string? TranscriptPreview);

/// <summary>
/// Request to transcribe a batch of audio files.
/// </summary>
internal sealed record BatchTranscribeRequest(
    string InputDirectory,
    string OutputDirectory,
    string? FilePattern = null,
    string? SummaryFilePath = null,
    bool StopOnFirstError = false,
    bool KeepIntermediateFiles = false,
    string? ConfigurationPath = null,
    int? MaxFiles = null);

/// <summary>
/// Structured result of a batch transcription run.
/// </summary>
internal sealed record BatchTranscribeResultDto(
    int TotalFiles,
    int Succeeded,
    int Failed,
    int Skipped,
    string? SummaryFilePath,
    TimeSpan TotalDuration,
    IReadOnlyList<BatchFileResultDto> Results);

/// <summary>
/// Result of processing one file in a batch.
/// </summary>
internal sealed record BatchFileResultDto(
    string InputPath,
    string OutputPath,
    string Status,
    string? ErrorMessage,
    TimeSpan Duration,
    string? DetectedLanguage);

/// <summary>
/// Structured model inspection result.
/// </summary>
internal sealed record ModelInfoResultDto(
    string ModelPath,
    string ModelType,
    bool Exists,
    long? FileSizeBytes,
    bool IsLoadable,
    bool NeedsDownload);

/// <summary>
/// Language information suitable for MCP responses.
/// </summary>
internal sealed record SupportedLanguageDto(
    string Code,
    string DisplayName,
    int Priority);

/// <summary>
/// Result of reading a transcript file.
/// </summary>
internal sealed record TranscriptReadResultDto(
    string Path,
    string Content,
    long TotalLength,
    bool WasTruncated);
