#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;

/// <summary>
/// Executes startup checks before the application begins transcription work.
/// </summary>
internal static class StartupValidationService
{
    /// <summary>
    /// Runs the configured startup checks and returns a summarized report.
    /// </summary>
    public static async Task<StartupValidationReport> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var checks = options.StartupValidation;
        var results = new List<StartupCheckResult>
        {
            StartupCheckResult.Passed("Settings file", options.ConfigurationPath),
            StartupCheckResult.Passed("Configured languages", options.GetSupportedLanguageSummary())
        };

        // Each check is recorded separately so the caller gets a complete preflight
        // report instead of failing on the first problem encountered.
        results.Add(options.IsBatchMode
            ? StartupCheckResult.Skipped("Input file", "Skipped in batch mode.")
            : checks.CheckInputFile
                ? CheckInputFile(options.InputFilePath)
                : StartupCheckResult.Skipped("Input file", "Check disabled by configuration."));

        results.AddRange(CheckOutputTargets(options, checks));

        results.Add(checks.CheckFfmpegAvailability
            ? await CheckFfmpegAsync(options, cancellationToken).ConfigureAwait(false)
            : StartupCheckResult.Skipped("ffmpeg", "Check disabled by configuration."));

        results.Add(checks.CheckModelType
            ? CheckModelType(options)
            : StartupCheckResult.Skipped("Model type", "Check disabled by configuration."));

        results.AddRange(CheckModelTarget(options, checks));

        results.Add(checks.CheckWhisperRuntime
            ? CheckWhisperRuntime()
            : StartupCheckResult.Skipped("Whisper runtime", "Check disabled by configuration."));

        results.Add(checks.CheckLanguageSupport
            ? CheckLanguageSupport(options)
            : StartupCheckResult.Skipped("Language support", "Check disabled by configuration."));

        if (options.IsBatchMode)
        {
            results.AddRange(CheckBatchTargets(options.Batch));
        }

        return new StartupValidationReport(results);
    }

    /// <summary>
    /// Verifies that the configured input file exists.
    /// </summary>
    private static StartupCheckResult CheckInputFile(string inputFilePath)
    {
        var fileInfo = new FileInfo(inputFilePath);
        if (!fileInfo.Exists)
        {
            return StartupCheckResult.Failed("Input file", $"Not found: {inputFilePath}");
        }

        return StartupCheckResult.Passed("Input file", $"{inputFilePath} ({fileInfo.Length} bytes)");
    }

    /// <summary>
    /// Verifies that output directories exist and are writable when enabled.
    /// </summary>
    private static IEnumerable<StartupCheckResult> CheckOutputTargets(
        TranscriptionOptions options,
        StartupValidationOptions checks)
    {
        yield return checks.CheckOutputDirectories
            ? CheckDirectoryExists(options.WavFilePath, "WAV output directory")
            : StartupCheckResult.Skipped("WAV output directory", "Check disabled by configuration.");

        yield return checks.CheckOutputDirectories
            ? CheckDirectoryExists(options.ResultFilePath, "Result output directory")
            : StartupCheckResult.Skipped("Result output directory", "Check disabled by configuration.");

        yield return checks.CheckOutputWriteAccess
            ? CheckDirectoryWriteAccess(options.WavFilePath, "WAV output directory")
            : StartupCheckResult.Skipped("WAV output writability", "Check disabled by configuration.");

        yield return checks.CheckOutputWriteAccess
            ? CheckDirectoryWriteAccess(options.ResultFilePath, "Result output directory")
            : StartupCheckResult.Skipped("Result output writability", "Check disabled by configuration.");
    }

    /// <summary>
    /// Verifies that ffmpeg can be executed and reports its version line.
    /// </summary>
    private static async Task<StartupCheckResult> CheckFfmpegAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        try
        {
            var version = await AudioConversionService.GetFfmpegVersionAsync(options, cancellationToken)
                .ConfigureAwait(false);
            return StartupCheckResult.Passed("ffmpeg", version);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed("ffmpeg", ex.Message);
        }
    }

    /// <summary>
    /// Verifies that the configured model type is recognized by Whisper.net.
    /// </summary>
    private static StartupCheckResult CheckModelType(TranscriptionOptions options)
    {
        try
        {
            var modelType = ModelService.ParseModelType(options.ModelType);
            return StartupCheckResult.Passed("Model type", modelType.ToString());
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed("Model type", ex.Message);
        }
    }

    /// <summary>
    /// Verifies model directory prerequisites and current model-file state.
    /// </summary>
    private static IEnumerable<StartupCheckResult> CheckModelTarget(
        TranscriptionOptions options,
        StartupValidationOptions checks)
    {
        yield return checks.CheckModelDirectory
            ? CheckDirectoryExists(options.ModelFilePath, "Model directory")
            : StartupCheckResult.Skipped("Model directory", "Check disabled by configuration.");

        yield return checks.CheckModelDirectory
            ? CheckDirectoryWriteAccess(options.ModelFilePath, "Model directory")
            : StartupCheckResult.Skipped("Model directory writability", "Check disabled by configuration.");

        yield return checks.CheckModelLoadability
            ? CheckModelState(options)
            : StartupCheckResult.Skipped("Model file state", "Check disabled by configuration.");
    }

    /// <summary>
    /// Verifies that the native Whisper runtime can be loaded on the current machine.
    /// </summary>
    private static StartupCheckResult CheckWhisperRuntime()
    {
        try
        {
            var runtimeInfo = WhisperFactory.GetRuntimeInfo();
            return StartupCheckResult.Passed("Whisper runtime", runtimeInfo?.ToString() ?? "Runtime loaded.");
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed("Whisper runtime", ex.Message);
        }
    }

    /// <summary>
    /// Verifies that all configured languages are supported by the loaded Whisper runtime.
    /// </summary>
    private static StartupCheckResult CheckLanguageSupport(TranscriptionOptions options)
    {
        try
        {
            var reportedLanguages = WhisperFactory.GetSupportedLanguages()
                .Select(language => language?.ToString()?.Trim() ?? string.Empty)
                .Where(language => !string.IsNullOrWhiteSpace(language))
                .ToArray();

            if (reportedLanguages.Length == 0)
            {
                return StartupCheckResult.Failed("Language support", "Whisper runtime returned no supported languages.");
            }

            var unsupported = options.SupportedLanguages
                .Where(language => !reportedLanguages.Any(reported => LanguageMatches(reported, language)))
                .Select(language => language.Code)
                .ToArray();

            if (unsupported.Length > 0)
            {
                return StartupCheckResult.Failed(
                    "Language support",
                    $"Configured language codes are not supported: {string.Join(", ", unsupported)}");
            }

            return StartupCheckResult.Passed(
                "Language support",
                $"All configured languages are supported: {string.Join(", ", options.SupportedLanguages.Select(language => language.Code))}");
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed("Language support", ex.Message);
        }
    }

    /// <summary>
    /// Verifies that the target directory for a file path exists.
    /// </summary>
    private static StartupCheckResult CheckDirectoryExists(string targetFilePath, string label)
    {
        var directoryPath = GetTargetDirectoryPath(targetFilePath);
        if (!Directory.Exists(directoryPath))
        {
            return StartupCheckResult.Failed(label, $"Directory not found: {directoryPath}");
        }

        return StartupCheckResult.Passed(label, directoryPath);
    }

    /// <summary>
    /// Verifies that a file can be created and deleted in the target directory.
    /// </summary>
    private static StartupCheckResult CheckDirectoryWriteAccess(string targetFilePath, string label)
    {
        var directoryPath = GetTargetDirectoryPath(targetFilePath);
        if (!Directory.Exists(directoryPath))
        {
            return StartupCheckResult.Failed(label, $"Directory not found: {directoryPath}");
        }

        var tempFilePath = Path.Combine(directoryPath, $".startup-check-{Guid.NewGuid():N}.tmp");

        try
        {
            using (File.Create(tempFilePath))
            {
            }

            // Delete the probe file immediately so the check does not leave artifacts behind.
            File.Delete(tempFilePath);
            return StartupCheckResult.Passed(label, $"Writable: {directoryPath}");
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed(label, $"Directory is not writable: {directoryPath}. {ex.Message}");
        }
    }

    /// <summary>
    /// Reports whether the configured model file is ready now or will need to be downloaded later.
    /// </summary>
    private static StartupCheckResult CheckModelState(TranscriptionOptions options)
    {
        var modelFileInfo = new FileInfo(options.ModelFilePath);
        if (!modelFileInfo.Exists)
        {
            return StartupCheckResult.Warning(
                "Model file state",
                $"Model file is missing and will be downloaded during execution: {options.ModelFilePath}");
        }

        if (modelFileInfo.Length == 0)
        {
            return StartupCheckResult.Warning(
                "Model file state",
                $"Model file is empty and will be re-downloaded during execution: {options.ModelFilePath}");
        }

        try
        {
            using var whisperFactory = WhisperFactory.FromPath(options.ModelFilePath);
            return StartupCheckResult.Passed(
                "Model file state",
                $"Model file is loadable: {options.ModelFilePath} ({modelFileInfo.Length} bytes)");
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Warning(
                "Model file state",
                $"Model file is not loadable and will be re-downloaded during execution: {ex.Message}");
        }
    }

    /// <summary>
    /// Verifies batch-specific prerequisites when batch mode is active.
    /// </summary>
    private static IEnumerable<StartupCheckResult> CheckBatchTargets(BatchOptions batch)
    {
        if (!Directory.Exists(batch.InputDirectory))
        {
            yield return StartupCheckResult.Failed("Batch input directory", $"Directory not found: {batch.InputDirectory}");
        }
        else
        {
            var matchingFiles = Directory.GetFiles(batch.InputDirectory, batch.FilePattern);
            yield return matchingFiles.Length > 0
                ? StartupCheckResult.Passed("Batch input directory", $"{matchingFiles.Length} file(s) matching '{batch.FilePattern}' in: {batch.InputDirectory}")
                : StartupCheckResult.Failed("Batch input directory", $"No files matching '{batch.FilePattern}' in: {batch.InputDirectory}");
        }

        if (!Directory.Exists(batch.OutputDirectory))
        {
            yield return StartupCheckResult.Failed("Batch output directory", $"Directory not found: {batch.OutputDirectory}");
        }
        else
        {
            yield return CheckDirectoryWriteAccessDirect(batch.OutputDirectory, "Batch output directory");
        }

        if (!Directory.Exists(batch.TempDirectory))
        {
            yield return StartupCheckResult.Failed("Batch temp directory", $"Directory not found: {batch.TempDirectory}");
        }
        else
        {
            yield return CheckDirectoryWriteAccessDirect(batch.TempDirectory, "Batch temp directory");
        }
    }

    /// <summary>
    /// Verifies that a file can be created and deleted in a directory path.
    /// </summary>
    private static StartupCheckResult CheckDirectoryWriteAccessDirect(string directoryPath, string label)
    {
        var tempFilePath = Path.Combine(directoryPath, $".startup-check-{Guid.NewGuid():N}.tmp");

        try
        {
            using (File.Create(tempFilePath))
            {
            }

            File.Delete(tempFilePath);
            return StartupCheckResult.Passed(label, $"Writable: {directoryPath}");
        }
        catch (Exception ex)
        {
            return StartupCheckResult.Failed(label, $"Directory is not writable: {directoryPath}. {ex.Message}");
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

/// <summary>
/// Summarizes the result of startup validation.
/// </summary>
internal sealed class StartupValidationReport
{
    public StartupValidationReport(IReadOnlyList<StartupCheckResult> results)
    {
        Results = results;
    }

    public IReadOnlyList<StartupCheckResult> Results { get; }
    public bool CanStart => Results.All(result => result.Status != StartupCheckStatus.Failed);
    public bool HasWarnings => Results.Any(result => result.Status == StartupCheckStatus.Warning);
    public string Outcome => CanStart
        ? HasWarnings ? "PASSED WITH WARNINGS" : "PASSED"
        : "FAILED";
}

/// <summary>
/// Represents one startup check result.
/// </summary>
internal sealed record StartupCheckResult(
    StartupCheckStatus Status,
    string Name,
    string Details)
{
    public static StartupCheckResult Passed(string name, string details) => new(StartupCheckStatus.Passed, name, details);
    public static StartupCheckResult Warning(string name, string details) => new(StartupCheckStatus.Warning, name, details);
    public static StartupCheckResult Failed(string name, string details) => new(StartupCheckStatus.Failed, name, details);
    public static StartupCheckResult Skipped(string name, string details) => new(StartupCheckStatus.Skipped, name, details);
}

/// <summary>
/// Lists the statuses available for startup checks.
/// </summary>
internal enum StartupCheckStatus
{
    Passed,
    Warning,
    Failed,
    Skipped
}

/// <summary>
/// Writes startup validation results to the console.
/// </summary>
internal static class StartupValidationConsoleReporter
{
    private static readonly bool UseAnsiColors = !Console.IsOutputRedirected;

    /// <summary>
    /// Prints the startup validation report and a final outcome summary.
    /// </summary>
    public static void Write(StartupValidationReport report, bool printDetailedReport)
    {
        Console.WriteLine(Colorize("=== Startup Validation ===", "96"));

        if (printDetailedReport)
        {
            foreach (var result in report.Results)
            {
                var statusLabel = $"[{MapStatus(result.Status)}]";
                Console.WriteLine($"{ColorizeStatus(statusLabel, result.Status)} {result.Name}: {result.Details}");
            }
        }

        var outcomeLabel = ColorizeOutcome(report.Outcome);
        Console.WriteLine(
            $"Startup validation outcome: {outcomeLabel} " +
            $"(passed: {report.Results.Count(result => result.Status == StartupCheckStatus.Passed)}, " +
            $"warnings: {report.Results.Count(result => result.Status == StartupCheckStatus.Warning)}, " +
            $"failed: {report.Results.Count(result => result.Status == StartupCheckStatus.Failed)}, " +
            $"skipped: {report.Results.Count(result => result.Status == StartupCheckStatus.Skipped)})");
    }

    /// <summary>
    /// Maps internal validation statuses to compact console labels.
    /// </summary>
    private static string MapStatus(StartupCheckStatus status)
    {
        return status switch
        {
            StartupCheckStatus.Passed => "PASS",
            StartupCheckStatus.Warning => "WARN",
            StartupCheckStatus.Failed => "FAIL",
            StartupCheckStatus.Skipped => "SKIP",
            _ => status.ToString().ToUpperInvariant()
        };
    }

    /// <summary>
    /// Applies the configured console color for one startup status label.
    /// </summary>
    private static string ColorizeStatus(string text, StartupCheckStatus status)
    {
        return status switch
        {
            StartupCheckStatus.Passed => Colorize(text, "92"),
            StartupCheckStatus.Warning => Colorize(text, "93"),
            StartupCheckStatus.Failed => Colorize(text, "91"),
            StartupCheckStatus.Skipped => Colorize(text, "90"),
            _ => text
        };
    }

    /// <summary>
    /// Applies the configured console color for the final validation outcome.
    /// </summary>
    private static string ColorizeOutcome(string outcome)
    {
        return outcome switch
        {
            "PASSED" => Colorize(outcome, "92"),
            "PASSED WITH WARNINGS" => Colorize(outcome, "93"),
            "FAILED" => Colorize(outcome, "91"),
            _ => outcome
        };
    }

    /// <summary>
    /// Wraps text in ANSI color codes when the output is interactive.
    /// </summary>
    private static string Colorize(string text, string colorCode)
    {
        if (!UseAnsiColors || string.IsNullOrEmpty(text))
        {
            return text;
        }

        return $"\u001b[{colorCode}m{text}\u001b[0m";
    }
}
