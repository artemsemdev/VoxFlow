#nullable enable
using System;

/// <summary>
/// Renders a colored progress bar that shows the current transcription stage and overall progress.
/// </summary>
internal sealed class ConsoleProgressService
{
    private static readonly char[] SpinnerFrames = ['|', '/', '-', '\\'];

    private readonly ConsoleProgressOptions options;
    private readonly bool useAnsiColors;
    private readonly bool useInteractiveUpdates;
    private readonly object sync = new();

    private DateTime lastRenderUtc = DateTime.MinValue;
    private DateTime transcriptionStartedUtc = DateTime.UtcNow;
    private int totalLanguageCount;
    private int currentLanguageIndex;
    private string currentLanguageName = string.Empty;
    private int latestLanguageProgress;
    private long spinnerIndex;
    private int? batchFileIndex;
    private int? batchTotalFiles;
    private string? batchFileName;

    /// <summary>
    /// Initializes the console progress renderer from configuration.
    /// </summary>
    public ConsoleProgressService(ConsoleProgressOptions options)
    {
        this.options = options;
        useAnsiColors = options.UseColors && !Console.IsOutputRedirected;
        useInteractiveUpdates = options.Enabled && !Console.IsOutputRedirected;
    }

    /// <summary>
    /// Sets the batch-level context shown as a prefix in progress output.
    /// </summary>
    public void SetBatchContext(int fileIndex, int totalFiles, string fileName)
    {
        lock (sync)
        {
            batchFileIndex = fileIndex;
            batchTotalFiles = totalFiles;
            batchFileName = fileName;
        }
    }

    /// <summary>
    /// Starts tracking progress for the transcription stage.
    /// </summary>
    public void StartTranscription(int totalLanguageCount)
    {
        if (!options.Enabled)
        {
            return;
        }

        lock (sync)
        {
            this.totalLanguageCount = Math.Max(totalLanguageCount, 1);
            currentLanguageIndex = 0;
            latestLanguageProgress = 0;
            transcriptionStartedUtc = DateTime.UtcNow;
            Render(force: true, "Preparing transcription candidates...");
        }
    }

    /// <summary>
    /// Marks the start of one language candidate pass.
    /// </summary>
    public void StartLanguage(int languageIndex, string languageName)
    {
        if (!options.Enabled)
        {
            return;
        }

        lock (sync)
        {
            currentLanguageIndex = languageIndex;
            currentLanguageName = languageName;
            latestLanguageProgress = 0;
            Render(force: true, $"Processing {languageName} candidate...");
        }
    }

    /// <summary>
    /// Updates progress for the current language candidate.
    /// </summary>
    public void UpdateLanguageProgress(int progressPercentage)
    {
        if (!options.Enabled)
        {
            return;
        }

        lock (sync)
        {
            latestLanguageProgress = Math.Clamp(progressPercentage, 0, 100);
            Render(force: latestLanguageProgress == 100, $"Processing {currentLanguageName} candidate...");
        }
    }

    /// <summary>
    /// Completes the current language and advances the bar to the next candidate.
    /// </summary>
    public void CompleteLanguage(string statusMessage)
    {
        if (!options.Enabled)
        {
            return;
        }

        lock (sync)
        {
            latestLanguageProgress = 100;
            Render(force: true, statusMessage);
            WriteLineBreak();
        }
    }

    /// <summary>
    /// Prints a final transcription-stage status line.
    /// </summary>
    public void CompleteTranscription(string statusMessage)
    {
        if (!options.Enabled)
        {
            return;
        }

        lock (sync)
        {
            currentLanguageIndex = totalLanguageCount;
            latestLanguageProgress = 100;
            Render(force: true, statusMessage);
            WriteLineBreak();
        }
    }

    private void Render(bool force, string statusMessage)
    {
        if (!force && DateTime.UtcNow - lastRenderUtc < TimeSpan.FromMilliseconds(options.RefreshIntervalMilliseconds))
        {
            return;
        }

        lastRenderUtc = DateTime.UtcNow;

        var overallProgress = ((double)currentLanguageIndex + latestLanguageProgress / 100d) / totalLanguageCount;
        var clampedOverallProgress = Math.Clamp(overallProgress, 0d, 1d);
        var completedBlocks = (int)Math.Round(clampedOverallProgress * options.ProgressBarWidth, MidpointRounding.AwayFromZero);
        var remainingBlocks = Math.Max(options.ProgressBarWidth - completedBlocks, 0);
        var processedPercentage = clampedOverallProgress * 100d;
        var remainingPercentage = Math.Max(0d, 100d - processedPercentage);
        var elapsed = DateTime.UtcNow - transcriptionStartedUtc;
        var spinner = SpinnerFrames[spinnerIndex++ % SpinnerFrames.Length];

        var completedBar = new string('#', completedBlocks);
        var remainingBar = new string('-', remainingBlocks);
        var bar = $"[{Colorize(completedBar, "96")}{Colorize(remainingBar, "90")}]";
        var batchPrefix = batchFileIndex.HasValue && batchTotalFiles.HasValue
            ? $"[File {batchFileIndex.Value}/{batchTotalFiles.Value}] "
            : "";
        var line =
            $"{batchPrefix}{Colorize(spinner.ToString(), "93")} {bar} " +
            $"{Colorize($"{processedPercentage,6:0.0}%", "92")} done | " +
            $"{Colorize($"{remainingPercentage,6:0.0}%", "91")} left | " +
            $"Language {Math.Min(currentLanguageIndex + 1, totalLanguageCount)}/{totalLanguageCount} " +
            $"({currentLanguageName}) | Elapsed {elapsed:hh\\:mm\\:ss} | {statusMessage}";

        if (useInteractiveUpdates)
        {
            Console.Write("\r\u001b[2K");
            Console.Write(line);
        }
        else
        {
            Console.WriteLine(line);
        }
    }

    private void WriteLineBreak()
    {
        if (useInteractiveUpdates)
        {
            Console.WriteLine();
        }
    }

    private string Colorize(string text, string colorCode)
    {
        if (!useAnsiColors || string.IsNullOrEmpty(text))
        {
            return text;
        }

        return $"\u001b[{colorCode}m{text}\u001b[0m";
    }
}
