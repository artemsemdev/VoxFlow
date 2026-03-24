using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using Whisper.net;
using Whisper.net.Ggml;

namespace VoxFlow.Core.Services;

/// <summary>
/// Loads, validates, and downloads Whisper models used by the application.
/// </summary>
internal sealed class ModelService : IModelService
{
    private WhisperFactory? _cachedFactory;
    private string? _cachedModelPath;

    /// <summary>
    /// Returns a cached factory if available, or creates a new one from the configured model.
    /// Downloads the model if needed.
    /// </summary>
    public async Task<WhisperFactory> GetOrCreateFactoryAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        if (_cachedFactory != null && _cachedModelPath == options.ModelFilePath)
            return _cachedFactory;

        _cachedFactory = await CreateFactoryInternalAsync(options, cancellationToken);
        _cachedModelPath = options.ModelFilePath;
        return _cachedFactory;
    }

    /// <summary>
    /// Returns metadata about the configured model without loading it.
    /// </summary>
    public ModelInfo InspectModel(TranscriptionOptions options)
    {
        var fileInfo = new FileInfo(options.ModelFilePath);
        var exists = fileInfo.Exists;
        var fileSizeBytes = exists ? fileInfo.Length : (long?)null;
        var isLoadable = false;
        var needsDownload = !exists || fileInfo.Length == 0;

        if (exists && fileInfo.Length > 0)
        {
            try
            {
                using var factory = WhisperFactory.FromPath(options.ModelFilePath);
                isLoadable = true;
            }
            catch
            {
                needsDownload = true;
            }
        }

        return new ModelInfo(
            options.ModelFilePath,
            options.ModelType,
            exists,
            fileSizeBytes,
            isLoadable,
            needsDownload);
    }

    /// <summary>
    /// Creates a Whisper factory from the configured model, downloading the model if needed.
    /// </summary>
    private async Task<WhisperFactory> CreateFactoryInternalAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var modelType = ParseModelType(options.ModelType);

        // Prefer reuse because model download is large, slow, and unnecessary when
        // the configured file already exists and can be loaded successfully.
        if (TryCreateFactory(options.ModelFilePath, out var whisperFactory, out var initialError))
        {
            return whisperFactory;
        }

        if (WhisperRuntimeFailureFormatter.IsFatalPlatformCompatibilityFailure(initialError))
        {
            throw new InvalidOperationException(initialError);
        }

        await DownloadModelAsync(options.ModelFilePath, modelType, cancellationToken).ConfigureAwait(false);

        if (TryCreateFactory(options.ModelFilePath, out whisperFactory, out var error))
        {
            return whisperFactory;
        }

        if (WhisperRuntimeFailureFormatter.IsFatalPlatformCompatibilityFailure(error))
        {
            throw new InvalidOperationException(error);
        }

        throw new InvalidOperationException(
            $"Model download completed but the model could not be loaded: {error}");
    }

    /// <summary>
    /// Parses the configured model type into the Whisper.net enum used by the downloader.
    /// </summary>
    internal static GgmlType ParseModelType(string modelType)
    {
        if (Enum.TryParse<GgmlType>(modelType, ignoreCase: true, out var parsedModelType))
        {
            return parsedModelType;
        }

        throw new InvalidOperationException($"Unsupported model type configured: {modelType}");
    }

    /// <summary>
    /// Attempts to create a Whisper factory without downloading any model data.
    /// </summary>
    private static bool TryCreateFactory(string modelFilePath, out WhisperFactory whisperFactory, out string error)
    {
        whisperFactory = null!;
        error = string.Empty;

        try
        {
            var fileInfo = new FileInfo(modelFilePath);
            if (!fileInfo.Exists || fileInfo.Length == 0)
            {
                error = "Model file is missing or empty.";
                return false;
            }

            whisperFactory = WhisperFactory.FromPath(modelFilePath);
            return true;
        }
        catch (Exception ex)
        {
            error = WhisperRuntimeFailureFormatter.GetFriendlyMessage(ex);
            whisperFactory?.Dispose();
            whisperFactory = null!;
            return false;
        }
    }

    /// <summary>
    /// Downloads the configured model to a temporary file and then replaces the target file atomically.
    /// </summary>
    private static async Task DownloadModelAsync(
        string modelFilePath,
        GgmlType ggmlType,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var directory = Path.GetDirectoryName(Path.GetFullPath(modelFilePath));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporaryFilePath = modelFilePath + ".download";

        try
        {
            using var modelStream = await WhisperGgmlDownloader.Default
                .GetGgmlModelAsync(ggmlType, QuantizationType.NoQuantization)
                .WaitAsync(cancellationToken)
                .ConfigureAwait(false);
            await using (var fileWriter = File.Create(temporaryFilePath))
            {
                // Write to a temporary file first so cancellation or partial downloads
                // never leave the configured model path in a corrupted state.
                await modelStream.CopyToAsync(fileWriter, cancellationToken).ConfigureAwait(false);
            }

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryFilePath, modelFilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryFilePath))
            {
                File.Delete(temporaryFilePath);
            }
        }
    }
}
