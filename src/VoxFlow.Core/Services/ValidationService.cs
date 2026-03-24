#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Services;

/// <summary>
/// Executes startup checks before the application begins transcription work.
/// </summary>
internal sealed class ValidationService : IValidationService
{
    private readonly IAudioConversionService _audioConversion;

    public ValidationService(IAudioConversionService audioConversion)
    {
        _audioConversion = audioConversion;
    }

    /// <summary>
    /// Runs the configured startup checks and returns a summarized result.
    /// </summary>
    public async Task<ValidationResult> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var checks = options.StartupValidation;
        var results = new List<ValidationCheck>
        {
            new("Settings file", ValidationCheckStatus.Passed, options.ConfigurationPath),
            new("Configured languages", ValidationCheckStatus.Passed, options.GetSupportedLanguageSummary())
        };

        // Each check is recorded separately so the caller gets a complete preflight
        // report instead of failing on the first problem encountered.
        results.Add(options.IsBatchMode
            ? new ValidationCheck("Input file", ValidationCheckStatus.Skipped, "Skipped in batch mode.")
            : checks.CheckInputFile
                ? CheckInputFile(options.InputFilePath)
                : new ValidationCheck("Input file", ValidationCheckStatus.Skipped, "Check disabled by configuration."));

        results.AddRange(CheckOutputTargets(options, checks));

        results.Add(checks.CheckFfmpegAvailability
            ? await CheckFfmpegAsync(options, cancellationToken).ConfigureAwait(false)
            : new ValidationCheck("ffmpeg", ValidationCheckStatus.Skipped, "Check disabled by configuration."));

        results.Add(checks.CheckModelType
            ? CheckModelType(options)
            : new ValidationCheck("Model type", ValidationCheckStatus.Skipped, "Check disabled by configuration."));

        results.AddRange(CheckModelTarget(options, checks));

        results.Add(checks.CheckWhisperRuntime
            ? CheckWhisperRuntime()
            : new ValidationCheck("Whisper runtime", ValidationCheckStatus.Skipped, "Check disabled by configuration."));

        results.Add(checks.CheckLanguageSupport
            ? CheckLanguageSupport(options)
            : new ValidationCheck("Language support", ValidationCheckStatus.Skipped, "Check disabled by configuration."));

        if (options.IsBatchMode)
        {
            results.AddRange(CheckBatchTargets(options.Batch));
        }

        var canStart = results.All(r => r.Status != ValidationCheckStatus.Failed);
        var hasWarnings = results.Any(r => r.Status == ValidationCheckStatus.Warning);
        var outcome = canStart
            ? hasWarnings ? "PASSED WITH WARNINGS" : "PASSED"
            : "FAILED";

        return new ValidationResult(outcome, canStart, hasWarnings, options.ConfigurationPath, results);
    }

    /// <summary>
    /// Verifies that the configured input file exists.
    /// </summary>
    private static ValidationCheck CheckInputFile(string inputFilePath)
    {
        var fileInfo = new FileInfo(inputFilePath);
        if (!fileInfo.Exists)
        {
            return new ValidationCheck("Input file", ValidationCheckStatus.Failed, $"Not found: {inputFilePath}");
        }

        return new ValidationCheck("Input file", ValidationCheckStatus.Passed, $"{inputFilePath} ({fileInfo.Length} bytes)");
    }

    /// <summary>
    /// Verifies that output directories exist and are writable when enabled.
    /// </summary>
    private static IEnumerable<ValidationCheck> CheckOutputTargets(
        TranscriptionOptions options,
        StartupValidationOptions checks)
    {
        yield return checks.CheckOutputDirectories
            ? CheckDirectoryExists(options.WavFilePath, "WAV output directory")
            : new ValidationCheck("WAV output directory", ValidationCheckStatus.Skipped, "Check disabled by configuration.");

        yield return checks.CheckOutputDirectories
            ? CheckDirectoryExists(options.ResultFilePath, "Result output directory")
            : new ValidationCheck("Result output directory", ValidationCheckStatus.Skipped, "Check disabled by configuration.");

        yield return checks.CheckOutputWriteAccess
            ? CheckDirectoryWriteAccess(options.WavFilePath, "WAV output directory")
            : new ValidationCheck("WAV output writability", ValidationCheckStatus.Skipped, "Check disabled by configuration.");

        yield return checks.CheckOutputWriteAccess
            ? CheckDirectoryWriteAccess(options.ResultFilePath, "Result output directory")
            : new ValidationCheck("Result output writability", ValidationCheckStatus.Skipped, "Check disabled by configuration.");
    }

    /// <summary>
    /// Verifies that ffmpeg can be executed from the configured path.
    /// </summary>
    private async Task<ValidationCheck> CheckFfmpegAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        try
        {
            var isValid = await _audioConversion.ValidateFfmpegAsync(options, cancellationToken)
                .ConfigureAwait(false);
            return isValid
                ? new ValidationCheck("ffmpeg", ValidationCheckStatus.Passed, "ffmpeg is available.")
                : new ValidationCheck("ffmpeg", ValidationCheckStatus.Failed, "ffmpeg validation failed.");
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return new ValidationCheck("ffmpeg", ValidationCheckStatus.Failed, ex.Message);
        }
    }

    /// <summary>
    /// Verifies that the configured model type is recognized by Whisper.net.
    /// </summary>
    private static ValidationCheck CheckModelType(TranscriptionOptions options)
    {
        try
        {
            if (Enum.TryParse<Whisper.net.Ggml.GgmlType>(options.ModelType, ignoreCase: true, out var modelType))
            {
                return new ValidationCheck("Model type", ValidationCheckStatus.Passed, modelType.ToString());
            }

            return new ValidationCheck("Model type", ValidationCheckStatus.Failed, $"Unsupported model type configured: {options.ModelType}");
        }
        catch (Exception ex)
        {
            return new ValidationCheck("Model type", ValidationCheckStatus.Failed, ex.Message);
        }
    }

    /// <summary>
    /// Verifies model directory prerequisites and current model-file state.
    /// </summary>
    private static IEnumerable<ValidationCheck> CheckModelTarget(
        TranscriptionOptions options,
        StartupValidationOptions checks)
    {
        yield return checks.CheckModelDirectory
            ? CheckDirectoryExists(options.ModelFilePath, "Model directory")
            : new ValidationCheck("Model directory", ValidationCheckStatus.Skipped, "Check disabled by configuration.");

        yield return checks.CheckModelDirectory
            ? CheckDirectoryWriteAccess(options.ModelFilePath, "Model directory")
            : new ValidationCheck("Model directory writability", ValidationCheckStatus.Skipped, "Check disabled by configuration.");

        yield return checks.CheckModelLoadability
            ? CheckModelState(options)
            : new ValidationCheck("Model file state", ValidationCheckStatus.Skipped, "Check disabled by configuration.");
    }

    /// <summary>
    /// Verifies that the native Whisper runtime can be loaded on the current machine.
    /// </summary>
    private static ValidationCheck CheckWhisperRuntime()
    {
        try
        {
            var runtimeInfo = WhisperFactory.GetRuntimeInfo();
            return new ValidationCheck("Whisper runtime", ValidationCheckStatus.Passed, runtimeInfo?.ToString() ?? "Runtime loaded.");
        }
        catch (Exception ex)
        {
            return new ValidationCheck("Whisper runtime", ValidationCheckStatus.Failed, ex.Message);
        }
    }

    /// <summary>
    /// Verifies that all configured languages are supported by the loaded Whisper runtime.
    /// </summary>
    private static ValidationCheck CheckLanguageSupport(TranscriptionOptions options)
    {
        try
        {
            var reportedLanguages = WhisperFactory.GetSupportedLanguages()
                .Select(language => language?.ToString()?.Trim() ?? string.Empty)
                .Where(language => !string.IsNullOrWhiteSpace(language))
                .ToArray();

            if (reportedLanguages.Length == 0)
            {
                return new ValidationCheck("Language support", ValidationCheckStatus.Failed, "Whisper runtime returned no supported languages.");
            }

            var unsupported = options.SupportedLanguages
                .Where(language => !reportedLanguages.Any(reported => LanguageMatches(reported, language)))
                .Select(language => language.Code)
                .ToArray();

            if (unsupported.Length > 0)
            {
                return new ValidationCheck(
                    "Language support",
                    ValidationCheckStatus.Failed,
                    $"Configured language codes are not supported: {string.Join(", ", unsupported)}");
            }

            return new ValidationCheck(
                "Language support",
                ValidationCheckStatus.Passed,
                $"All configured languages are supported: {string.Join(", ", options.SupportedLanguages.Select(language => language.Code))}");
        }
        catch (Exception ex)
        {
            return new ValidationCheck("Language support", ValidationCheckStatus.Failed, ex.Message);
        }
    }

    /// <summary>
    /// Verifies that the target directory for a file path exists.
    /// </summary>
    private static ValidationCheck CheckDirectoryExists(string targetFilePath, string label)
    {
        var directoryPath = GetTargetDirectoryPath(targetFilePath);
        if (!Directory.Exists(directoryPath))
        {
            return new ValidationCheck(label, ValidationCheckStatus.Failed, $"Directory not found: {directoryPath}");
        }

        return new ValidationCheck(label, ValidationCheckStatus.Passed, directoryPath);
    }

    /// <summary>
    /// Verifies that a file can be created and deleted in the target directory.
    /// </summary>
    private static ValidationCheck CheckDirectoryWriteAccess(string targetFilePath, string label)
    {
        var directoryPath = GetTargetDirectoryPath(targetFilePath);
        if (!Directory.Exists(directoryPath))
        {
            return new ValidationCheck(label, ValidationCheckStatus.Failed, $"Directory not found: {directoryPath}");
        }

        var tempFilePath = Path.Combine(directoryPath, $".startup-check-{Guid.NewGuid():N}.tmp");

        try
        {
            using (File.Create(tempFilePath))
            {
            }

            // Delete the probe file immediately so the check does not leave artifacts behind.
            File.Delete(tempFilePath);
            return new ValidationCheck(label, ValidationCheckStatus.Passed, $"Writable: {directoryPath}");
        }
        catch (Exception ex)
        {
            return new ValidationCheck(label, ValidationCheckStatus.Failed, $"Directory is not writable: {directoryPath}. {ex.Message}");
        }
    }

    /// <summary>
    /// Reports whether the configured model file is ready now or will need to be downloaded later.
    /// </summary>
    private static ValidationCheck CheckModelState(TranscriptionOptions options)
    {
        var modelFileInfo = new FileInfo(options.ModelFilePath);
        if (!modelFileInfo.Exists)
        {
            return new ValidationCheck(
                "Model file state",
                ValidationCheckStatus.Warning,
                $"Model file is missing and will be downloaded during execution: {options.ModelFilePath}");
        }

        if (modelFileInfo.Length == 0)
        {
            return new ValidationCheck(
                "Model file state",
                ValidationCheckStatus.Warning,
                $"Model file is empty and will be re-downloaded during execution: {options.ModelFilePath}");
        }

        try
        {
            using var whisperFactory = WhisperFactory.FromPath(options.ModelFilePath);
            return new ValidationCheck(
                "Model file state",
                ValidationCheckStatus.Passed,
                $"Model file is loadable: {options.ModelFilePath} ({modelFileInfo.Length} bytes)");
        }
        catch (Exception ex)
        {
            return new ValidationCheck(
                "Model file state",
                ValidationCheckStatus.Warning,
                $"Model file is not loadable and will be re-downloaded during execution: {ex.Message}");
        }
    }

    /// <summary>
    /// Verifies batch-specific prerequisites when batch mode is active.
    /// </summary>
    private static IEnumerable<ValidationCheck> CheckBatchTargets(BatchOptions batch)
    {
        if (!Directory.Exists(batch.InputDirectory))
        {
            yield return new ValidationCheck("Batch input directory", ValidationCheckStatus.Failed, $"Directory not found: {batch.InputDirectory}");
        }
        else
        {
            var matchingFiles = Directory.GetFiles(batch.InputDirectory, batch.FilePattern);
            yield return matchingFiles.Length > 0
                ? new ValidationCheck("Batch input directory", ValidationCheckStatus.Passed, $"{matchingFiles.Length} file(s) matching '{batch.FilePattern}' in: {batch.InputDirectory}")
                : new ValidationCheck("Batch input directory", ValidationCheckStatus.Failed, $"No files matching '{batch.FilePattern}' in: {batch.InputDirectory}");
        }

        if (!Directory.Exists(batch.OutputDirectory))
        {
            yield return new ValidationCheck("Batch output directory", ValidationCheckStatus.Failed, $"Directory not found: {batch.OutputDirectory}");
        }
        else
        {
            yield return CheckDirectoryWriteAccessDirect(batch.OutputDirectory, "Batch output directory");
        }

        if (!Directory.Exists(batch.TempDirectory))
        {
            yield return new ValidationCheck("Batch temp directory", ValidationCheckStatus.Failed, $"Directory not found: {batch.TempDirectory}");
        }
        else
        {
            yield return CheckDirectoryWriteAccessDirect(batch.TempDirectory, "Batch temp directory");
        }
    }

    /// <summary>
    /// Verifies that a file can be created and deleted in a directory path.
    /// </summary>
    private static ValidationCheck CheckDirectoryWriteAccessDirect(string directoryPath, string label)
    {
        var tempFilePath = Path.Combine(directoryPath, $".startup-check-{Guid.NewGuid():N}.tmp");

        try
        {
            using (File.Create(tempFilePath))
            {
            }

            File.Delete(tempFilePath);
            return new ValidationCheck(label, ValidationCheckStatus.Passed, $"Writable: {directoryPath}");
        }
        catch (Exception ex)
        {
            return new ValidationCheck(label, ValidationCheckStatus.Failed, $"Directory is not writable: {directoryPath}. {ex.Message}");
        }
    }

    /// <summary>
    /// Resolves the directory used by a configured target file path.
    /// </summary>
    private static string GetTargetDirectoryPath(string targetFilePath)
    {
        return Path.GetDirectoryName(Path.GetFullPath(targetFilePath)) ?? Directory.GetCurrentDirectory();
    }

    /// <summary>
    /// Matches a runtime-reported language entry against a configured language.
    /// </summary>
    private static bool LanguageMatches(string reportedLanguage, SupportedLanguage configuredLanguage)
    {
        var normalizedReported = reportedLanguage.Trim().ToLowerInvariant();
        var normalizedCode = configuredLanguage.Code.ToLowerInvariant();
        var normalizedName = configuredLanguage.DisplayName.ToLowerInvariant();

        // Whisper runtime output varies by platform and version, so matching accepts
        // code-only, name-only, and mixed display formats such as "English (en)".
        return normalizedReported == normalizedCode ||
               normalizedReported == normalizedName ||
               normalizedReported.StartsWith(normalizedCode + " ", StringComparison.Ordinal) ||
               normalizedReported.Contains("(" + normalizedCode + ")", StringComparison.Ordinal) ||
               normalizedReported.Contains("[" + normalizedCode + "]", StringComparison.Ordinal) ||
               normalizedReported.EndsWith(" " + normalizedCode, StringComparison.Ordinal) ||
               normalizedReported.Contains(normalizedName, StringComparison.Ordinal);
    }
}
