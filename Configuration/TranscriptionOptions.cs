#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

/// <summary>
/// Stores all validated runtime settings used by the transcription workflow.
/// </summary>
internal sealed class TranscriptionOptions
{
    public string ConfigurationPath { get; }
    public bool IsBatchMode { get; }
    public string InputFilePath { get; }
    public string WavFilePath { get; }
    public string ResultFilePath { get; }
    public string ModelFilePath { get; }
    public string ModelType { get; }
    public string FfmpegExecutablePath { get; }
    public int OutputSampleRate { get; }
    public int OutputChannelCount { get; }
    public string OutputContainerFormat { get; }
    public bool OverwriteWavOutput { get; }
    public IReadOnlyList<string> AudioFilterChain { get; }
    public IReadOnlyList<SupportedLanguage> SupportedLanguages { get; }
    public IReadOnlySet<string> NonSpeechMarkers { get; }
    public TimeSpan LongLowInformationSegmentThreshold { get; }
    public int MinTextLengthForLongSegment { get; }
    public float MinSegmentProbability { get; }
    public float MinWinningCandidateProbability { get; }
    public float MinWinningMargin { get; }
    public float TieBreakerEpsilon { get; }
    public bool RejectAmbiguousLanguageCandidates { get; }
    public TimeSpan MinAcceptedSpeechDuration { get; }
    public bool UseNoContext { get; }
    public float NoSpeechThreshold { get; }
    public float LogProbThreshold { get; }
    public float EntropyThreshold { get; }
    public bool SuppressBracketedNonSpeechSegments { get; }
    public int MaxConsecutiveDuplicateSegments { get; }
    public int MaxDuplicateSegmentTextLength { get; }
    public StartupValidationOptions StartupValidation { get; }
    public ConsoleProgressOptions ConsoleProgress { get; }
    public BatchOptions Batch { get; }

    /// <summary>
    /// Creates validated options from raw configuration data.
    /// </summary>
    private TranscriptionOptions(TranscriptionConfiguration configuration, string configurationPath)
    {
        ConfigurationPath = configurationPath;
        IsBatchMode = string.Equals(configuration.ProcessingMode, "batch", StringComparison.OrdinalIgnoreCase);

        // Single-file paths are only required in single-file mode.
        InputFilePath = IsBatchMode ? (configuration.InputFilePath?.Trim() ?? string.Empty) : RequireValue(configuration.InputFilePath, nameof(configuration.InputFilePath));
        WavFilePath = IsBatchMode ? (configuration.WavFilePath?.Trim() ?? string.Empty) : RequireValue(configuration.WavFilePath, nameof(configuration.WavFilePath));
        ResultFilePath = IsBatchMode ? (configuration.ResultFilePath?.Trim() ?? string.Empty) : RequireValue(configuration.ResultFilePath, nameof(configuration.ResultFilePath));
        ModelFilePath = RequireValue(configuration.ModelFilePath, nameof(configuration.ModelFilePath));
        ModelType = RequireValue(configuration.ModelType, nameof(configuration.ModelType));
        FfmpegExecutablePath = RequireValue(configuration.FfmpegExecutablePath, nameof(configuration.FfmpegExecutablePath));
        OutputSampleRate = EnsurePositive(configuration.OutputSampleRate, nameof(configuration.OutputSampleRate));
        OutputChannelCount = EnsurePositive(configuration.OutputChannelCount, nameof(configuration.OutputChannelCount));
        OutputContainerFormat = RequireValue(configuration.OutputContainerFormat, nameof(configuration.OutputContainerFormat));
        OverwriteWavOutput = configuration.OverwriteWavOutput;
        AudioFilterChain = CreateAudioFilterChain(configuration.AudioFilterChain);
        SupportedLanguages = CreateSupportedLanguages(configuration.SupportedLanguages);
        NonSpeechMarkers = CreateNonSpeechMarkers(configuration.NonSpeechMarkers);
        LongLowInformationSegmentThreshold = TimeSpan.FromSeconds(
            EnsurePositive(
                configuration.LongLowInformationSegmentThresholdSeconds,
                nameof(configuration.LongLowInformationSegmentThresholdSeconds)));
        MinTextLengthForLongSegment = EnsurePositive(
            configuration.MinTextLengthForLongSegment,
            nameof(configuration.MinTextLengthForLongSegment));
        MinSegmentProbability = EnsureProbability(
            configuration.MinSegmentProbability,
            nameof(configuration.MinSegmentProbability));
        MinWinningCandidateProbability = EnsureProbability(
            configuration.MinWinningCandidateProbability,
            nameof(configuration.MinWinningCandidateProbability));
        MinWinningMargin = EnsureProbability(configuration.MinWinningMargin, nameof(configuration.MinWinningMargin));
        TieBreakerEpsilon = EnsureNonNegative(configuration.TieBreakerEpsilon, nameof(configuration.TieBreakerEpsilon));
        RejectAmbiguousLanguageCandidates = configuration.RejectAmbiguousLanguageCandidates;
        MinAcceptedSpeechDuration = TimeSpan.FromSeconds(
            EnsurePositive(
                configuration.MinAcceptedSpeechDurationSeconds,
                nameof(configuration.MinAcceptedSpeechDurationSeconds)));
        UseNoContext = configuration.UseNoContext;
        NoSpeechThreshold = EnsureProbability(configuration.NoSpeechThreshold, nameof(configuration.NoSpeechThreshold));
        LogProbThreshold = EnsureNumber(configuration.LogProbThreshold, nameof(configuration.LogProbThreshold));
        EntropyThreshold = EnsureNonNegative(configuration.EntropyThreshold, nameof(configuration.EntropyThreshold));
        SuppressBracketedNonSpeechSegments = configuration.SuppressBracketedNonSpeechSegments;
        MaxConsecutiveDuplicateSegments = EnsurePositive(
            configuration.MaxConsecutiveDuplicateSegments,
            nameof(configuration.MaxConsecutiveDuplicateSegments));
        MaxDuplicateSegmentTextLength = EnsurePositive(
            configuration.MaxDuplicateSegmentTextLength,
            nameof(configuration.MaxDuplicateSegmentTextLength));
        StartupValidation = CreateStartupValidationOptions(configuration.StartupValidation);
        ConsoleProgress = CreateConsoleProgressOptions(configuration.ConsoleProgress);
        Batch = IsBatchMode ? CreateBatchOptions(configuration.Batch) : BatchOptions.Disabled;
    }

    /// <summary>
    /// Loads settings from the default configuration file location.
    /// </summary>
    public static TranscriptionOptions Load()
    {
        return LoadFromPath(ResolveConfigurationPath());
    }

    /// <summary>
    /// Loads settings from an explicit path. This is primarily useful for tests and custom launch flows.
    /// </summary>
    internal static TranscriptionOptions LoadFromPath(string configurationPath)
    {
        if (!File.Exists(configurationPath))
        {
            throw new FileNotFoundException($"Settings file was not found: {configurationPath}", configurationPath);
        }

        var json = File.ReadAllText(configurationPath);
        var jsonOptions = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        var root = JsonSerializer.Deserialize<TranscriptionSettingsRoot>(json, jsonOptions);

        if (root?.Transcription is null)
        {
            throw new InvalidOperationException(
                $"Settings file is missing the 'transcription' section: {configurationPath}");
        }

        return new TranscriptionOptions(root.Transcription, configurationPath);
    }

    /// <summary>
    /// Returns the configured languages as a human-readable list.
    /// </summary>
    public string GetSupportedLanguageSummary()
    {
        return string.Join(", ", SupportedLanguages.Select(language => language.DisplayName));
    }

    /// <summary>
    /// Resolves the configuration file path, optionally honoring an environment override.
    /// </summary>
    private static string ResolveConfigurationPath()
    {
        var configuredPath = Environment.GetEnvironmentVariable("TRANSCRIPTION_SETTINGS_PATH");
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return Path.GetFullPath(configuredPath);
        }

        return Path.Combine(AppContext.BaseDirectory, "appsettings.json");
    }

    /// <summary>
    /// Validates the configured supported languages and assigns tie-break priorities.
    /// </summary>
    private static IReadOnlyList<SupportedLanguage> CreateSupportedLanguages(
        IReadOnlyList<SupportedLanguageConfiguration>? configurations)
    {
        if (configurations is null || configurations.Count == 0)
        {
            throw new InvalidOperationException("Settings must define at least one supported language.");
        }

        var languages = configurations
            .Select((configuration, index) => new SupportedLanguage(
                RequireValue(configuration.Code, $"SupportedLanguages[{index}].Code"),
                RequireValue(configuration.DisplayName, $"SupportedLanguages[{index}].DisplayName"),
                index))
            .ToArray();

        if (languages.GroupBy(language => language.Code, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
        {
            throw new InvalidOperationException("Supported language codes must be unique.");
        }

        return languages;
    }

    /// <summary>
    /// Normalizes configured non-speech markers into a lookup set.
    /// </summary>
    private static IReadOnlySet<string> CreateNonSpeechMarkers(IReadOnlyList<string>? markers)
    {
        if (markers is null || markers.Count == 0)
        {
            throw new InvalidOperationException("Settings must define at least one non-speech marker.");
        }

        return new HashSet<string>(
            markers
                .Where(marker => !string.IsNullOrWhiteSpace(marker))
                .Select(marker => marker.Trim()),
            StringComparer.Ordinal);
    }

    /// <summary>
    /// Normalizes the configured ffmpeg audio filters into an ordered chain.
    /// </summary>
    private static IReadOnlyList<string> CreateAudioFilterChain(IReadOnlyList<string>? filters)
    {
        if (filters is null)
        {
            return Array.Empty<string>();
        }

        return filters
            .Where(filter => !string.IsNullOrWhiteSpace(filter))
            .Select(filter => filter.Trim())
            .ToArray();
    }

    /// <summary>
    /// Converts startup validation settings into an immutable runtime model.
    /// </summary>
    private static StartupValidationOptions CreateStartupValidationOptions(StartupValidationConfiguration? configuration)
    {
        if (configuration is null)
        {
            throw new InvalidOperationException("Settings must define the 'startupValidation' section.");
        }

        return new StartupValidationOptions(
            configuration.Enabled,
            configuration.PrintDetailedReport,
            configuration.CheckInputFile,
            configuration.CheckOutputDirectories,
            configuration.CheckOutputWriteAccess,
            configuration.CheckFfmpegAvailability,
            configuration.CheckModelType,
            configuration.CheckModelDirectory,
            configuration.CheckModelLoadability,
            configuration.CheckLanguageSupport,
            configuration.CheckWhisperRuntime);
    }

    /// <summary>
    /// Converts console progress settings into an immutable runtime model.
    /// </summary>
    private static ConsoleProgressOptions CreateConsoleProgressOptions(ConsoleProgressConfiguration? configuration)
    {
        if (configuration is null)
        {
            throw new InvalidOperationException("Settings must define the 'consoleProgress' section.");
        }

        return new ConsoleProgressOptions(
            configuration.Enabled,
            configuration.UseColors,
            EnsurePositive(configuration.ProgressBarWidth, nameof(configuration.ProgressBarWidth)),
            EnsurePositive(configuration.RefreshIntervalMilliseconds, nameof(configuration.RefreshIntervalMilliseconds)));
    }

    /// <summary>
    /// Converts batch processing settings into an immutable runtime model.
    /// Called only when processingMode is "batch".
    /// </summary>
    private static BatchOptions CreateBatchOptions(BatchConfiguration? configuration)
    {
        if (configuration is null)
        {
            throw new InvalidOperationException(
                "Settings must define the 'batch' section inside 'transcription' when processingMode is 'batch'.");
        }

        var inputDirectory = RequireValue(configuration.InputDirectory, nameof(configuration.InputDirectory));
        var outputDirectory = RequireValue(configuration.OutputDirectory, nameof(configuration.OutputDirectory));
        var filePattern = string.IsNullOrWhiteSpace(configuration.FilePattern) ? "*.m4a" : configuration.FilePattern.Trim();
        var tempDirectory = string.IsNullOrWhiteSpace(configuration.TempDirectory)
            ? Path.GetTempPath()
            : configuration.TempDirectory.Trim();
        var summaryFilePath = string.IsNullOrWhiteSpace(configuration.SummaryFilePath)
            ? "batch-summary.txt"
            : configuration.SummaryFilePath.Trim();

        return new BatchOptions(
            InputDirectory: inputDirectory,
            OutputDirectory: outputDirectory,
            TempDirectory: tempDirectory,
            FilePattern: filePattern,
            StopOnFirstError: configuration.StopOnFirstError,
            KeepIntermediateFiles: configuration.KeepIntermediateFiles,
            SummaryFilePath: summaryFilePath);
    }

    /// <summary>
    /// Ensures a required string setting is present.
    /// </summary>
    private static string RequireValue(string? value, string settingName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Settings value '{settingName}' is required.");
        }

        return value.Trim();
    }

    /// <summary>
    /// Ensures a numeric setting is greater than zero.
    /// </summary>
    private static int EnsurePositive(int value, string settingName)
    {
        if (value <= 0)
        {
            throw new InvalidOperationException($"Settings value '{settingName}' must be greater than zero.");
        }

        return value;
    }

    /// <summary>
    /// Ensures a probability setting is within the inclusive 0..1 range.
    /// </summary>
    private static float EnsureProbability(float value, string settingName)
    {
        if (value is < 0 or > 1)
        {
            throw new InvalidOperationException($"Settings value '{settingName}' must be between 0 and 1.");
        }

        return value;
    }

    /// <summary>
    /// Ensures a numeric setting is not negative.
    /// </summary>
    private static float EnsureNonNegative(float value, string settingName)
    {
        if (value < 0)
        {
            throw new InvalidOperationException($"Settings value '{settingName}' must be zero or greater.");
        }

        return value;
    }

    /// <summary>
    /// Ensures a numeric setting is a real finite number.
    /// </summary>
    private static float EnsureNumber(float value, string settingName)
    {
        if (float.IsNaN(value) || float.IsInfinity(value))
        {
            throw new InvalidOperationException($"Settings value '{settingName}' must be a finite number.");
        }

        return value;
    }
}

/// <summary>
/// Describes one configured supported language and its tie-break priority.
/// </summary>
internal sealed record SupportedLanguage(string Code, string DisplayName, int Priority);

/// <summary>
/// Represents the root of the JSON configuration file.
/// </summary>
internal sealed class TranscriptionSettingsRoot
{
    public TranscriptionConfiguration? Transcription { get; set; }
}

/// <summary>
/// Represents raw transcription settings loaded from JSON before validation.
/// </summary>
internal sealed class TranscriptionConfiguration
{
    public string? ProcessingMode { get; set; }
    public string? InputFilePath { get; set; }
    public string? WavFilePath { get; set; }
    public string? ResultFilePath { get; set; }
    public string? ModelFilePath { get; set; }
    public string? ModelType { get; set; }
    public string? FfmpegExecutablePath { get; set; }
    public int OutputSampleRate { get; set; }
    public int OutputChannelCount { get; set; }
    public string? OutputContainerFormat { get; set; }
    public bool OverwriteWavOutput { get; set; }
    public List<string>? AudioFilterChain { get; set; }
    public List<SupportedLanguageConfiguration>? SupportedLanguages { get; set; }
    public List<string>? NonSpeechMarkers { get; set; }
    public int LongLowInformationSegmentThresholdSeconds { get; set; }
    public int MinTextLengthForLongSegment { get; set; }
    public float MinSegmentProbability { get; set; }
    public float MinWinningCandidateProbability { get; set; }
    public float MinWinningMargin { get; set; }
    public float TieBreakerEpsilon { get; set; }
    public bool RejectAmbiguousLanguageCandidates { get; set; }
    public int MinAcceptedSpeechDurationSeconds { get; set; }
    public bool UseNoContext { get; set; }
    public float NoSpeechThreshold { get; set; }
    public float LogProbThreshold { get; set; }
    public float EntropyThreshold { get; set; }
    public bool SuppressBracketedNonSpeechSegments { get; set; }
    public int MaxConsecutiveDuplicateSegments { get; set; }
    public int MaxDuplicateSegmentTextLength { get; set; }
    public StartupValidationConfiguration? StartupValidation { get; set; }
    public ConsoleProgressConfiguration? ConsoleProgress { get; set; }
    public BatchConfiguration? Batch { get; set; }
}

/// <summary>
/// Represents one language entry from the JSON configuration file.
/// </summary>
internal sealed class SupportedLanguageConfiguration
{
    public string? Code { get; set; }
    public string? DisplayName { get; set; }
}

/// <summary>
/// Controls which startup validation checks run before transcription starts.
/// </summary>
internal sealed record StartupValidationOptions(
    bool Enabled,
    bool PrintDetailedReport,
    bool CheckInputFile,
    bool CheckOutputDirectories,
    bool CheckOutputWriteAccess,
    bool CheckFfmpegAvailability,
    bool CheckModelType,
    bool CheckModelDirectory,
    bool CheckModelLoadability,
    bool CheckLanguageSupport,
    bool CheckWhisperRuntime);

/// <summary>
/// Represents raw startup validation settings loaded from JSON.
/// </summary>
internal sealed class StartupValidationConfiguration
{
    public bool Enabled { get; set; }
    public bool PrintDetailedReport { get; set; }
    public bool CheckInputFile { get; set; }
    public bool CheckOutputDirectories { get; set; }
    public bool CheckOutputWriteAccess { get; set; }
    public bool CheckFfmpegAvailability { get; set; }
    public bool CheckModelType { get; set; }
    public bool CheckModelDirectory { get; set; }
    public bool CheckModelLoadability { get; set; }
    public bool CheckLanguageSupport { get; set; }
    public bool CheckWhisperRuntime { get; set; }
}

/// <summary>
/// Controls the colored console progress UI shown during transcription.
/// </summary>
internal sealed record ConsoleProgressOptions(
    bool Enabled,
    bool UseColors,
    int ProgressBarWidth,
    int RefreshIntervalMilliseconds);

/// <summary>
/// Represents raw console progress settings loaded from JSON.
/// </summary>
internal sealed class ConsoleProgressConfiguration
{
    public bool Enabled { get; set; }
    public bool UseColors { get; set; }
    public int ProgressBarWidth { get; set; }
    public int RefreshIntervalMilliseconds { get; set; }
}

/// <summary>
/// Stores validated batch processing settings used when processingMode is "batch".
/// </summary>
internal sealed record BatchOptions(
    string InputDirectory,
    string OutputDirectory,
    string TempDirectory,
    string FilePattern,
    bool StopOnFirstError,
    bool KeepIntermediateFiles,
    string SummaryFilePath)
{
    public static readonly BatchOptions Disabled = new(
        InputDirectory: string.Empty,
        OutputDirectory: string.Empty,
        TempDirectory: string.Empty,
        FilePattern: "*.m4a",
        StopOnFirstError: false,
        KeepIntermediateFiles: false,
        SummaryFilePath: string.Empty);
}

/// <summary>
/// Represents raw batch processing settings loaded from JSON inside the transcription section.
/// </summary>
internal sealed class BatchConfiguration
{
    public string? InputDirectory { get; set; }
    public string? OutputDirectory { get; set; }
    public string? TempDirectory { get; set; }
    public string? FilePattern { get; set; }
    public bool StopOnFirstError { get; set; }
    public bool KeepIntermediateFiles { get; set; }
    public string? SummaryFilePath { get; set; }
}
