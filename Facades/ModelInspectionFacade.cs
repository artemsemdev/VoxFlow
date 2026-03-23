#nullable enable
using System;
using System.IO;
using Whisper.net;

/// <summary>
/// Provides structured model inspection without triggering model download.
/// </summary>
internal sealed class ModelInspectionFacade : IModelInspectionFacade
{
    public ModelInfoResultDto InspectModel(string? configurationPath = null)
    {
        var options = string.IsNullOrWhiteSpace(configurationPath)
            ? TranscriptionOptions.Load()
            : TranscriptionOptions.LoadFromPath(configurationPath);

        var modelPath = options.ModelFilePath;
        var modelType = options.ModelType;
        var fileInfo = new FileInfo(modelPath);
        var exists = fileInfo.Exists;
        var fileSize = exists ? fileInfo.Length : (long?)null;

        var isLoadable = false;
        if (exists && fileInfo.Length > 0)
        {
            try
            {
                using var factory = WhisperFactory.FromPath(modelPath);
                isLoadable = true;
            }
            catch
            {
                // Model file exists but cannot be loaded.
            }
        }

        var needsDownload = !exists || fileInfo.Length == 0 || !isLoadable;

        return new ModelInfoResultDto(
            ModelPath: modelPath,
            ModelType: modelType,
            Exists: exists,
            FileSizeBytes: fileSize,
            IsLoadable: isLoadable,
            NeedsDownload: needsDownload);
    }
}
