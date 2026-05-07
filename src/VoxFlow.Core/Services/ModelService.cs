using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using Whisper.net;
using Whisper.net.Ggml;

namespace VoxFlow.Core.Services;

/// <summary>
/// Loads, validates, and downloads Whisper models used by the application.
/// </summary>
internal sealed class ModelService : IModelService, IDisposable
{
    private readonly ILogger<ModelService> _logger;
    private WhisperFactory? _cachedFactory;
    private string? _cachedModelPath;

    public ModelService(ILogger<ModelService>? logger = null)
    {
        _logger = logger ?? NullLogger<ModelService>.Instance;
    }

    /// <summary>
    /// Returns a cached factory if available, or creates a new one from the configured model.
    /// Downloads the model if needed.
    /// </summary>
    public async Task<WhisperFactory> GetOrCreateFactoryAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);

        // Cache by model path so repeated transcriptions reuse the same native model load, but config changes still force a reload.
        if (_cachedFactory != null && _cachedModelPath == options.ModelFilePath)
            return _cachedFactory;

        var newFactory = await CreateFactoryInternalAsync(options, cancellationToken);
        var previousFactory = _cachedFactory;

        _cachedFactory = newFactory;
        _cachedModelPath = options.ModelFilePath;
        previousFactory?.Dispose();

        return newFactory;
    }

    /// <summary>
    /// Returns metadata about the configured model without loading it.
    /// </summary>
    public ModelInfo InspectModel(TranscriptionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

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
            catch (Exception ex)
            {
                // Treat any load failure (corrupt file, version mismatch, native load
                // error) as "needs re-download". Logged via ILogger<ModelService> so
                // the operator can tell a corrupt-model recovery from a missing-model
                // first-run. Falls back to NullLogger when the host hasn't wired
                // logging — see ServiceCollectionExtensions logging contract.
                _logger.LogError(
                    ex,
                    "Whisper model at {ModelPath} failed to load; marking for re-download.",
                    options.ModelFilePath);
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

    public void Dispose()
    {
        _cachedFactory?.Dispose();
        _cachedFactory = null;
        _cachedModelPath = null;
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
