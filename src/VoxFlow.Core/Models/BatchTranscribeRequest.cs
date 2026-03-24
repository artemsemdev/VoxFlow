namespace VoxFlow.Core.Models;

public sealed record BatchTranscribeRequest(
    string InputDirectory,
    string OutputDirectory,
    string? FilePattern = null,
    string? SummaryFilePath = null,
    bool StopOnFirstError = false,
    bool KeepIntermediateFiles = false,
    string? ConfigurationPath = null,
    int? MaxFiles = null);
