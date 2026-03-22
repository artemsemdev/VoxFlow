#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Generates human-readable batch summary reports with per-file results.
/// </summary>
internal static class BatchSummaryWriter
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>
    /// Writes the batch summary report to the configured file path.
    /// </summary>
    public static async Task WriteAsync(
        string summaryFilePath,
        IReadOnlyList<FileProcessingResult> results,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var content = BuildSummaryText(results);
        await File.WriteAllTextAsync(summaryFilePath, content, Utf8NoBom, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Builds the summary report content for testing without writing to disk.
    /// </summary>
    internal static string BuildSummaryText(IReadOnlyList<FileProcessingResult> results)
    {
        var succeeded = results.Count(r => r.Status == FileProcessingStatus.Success);
        var failed = results.Count(r => r.Status == FileProcessingStatus.Failed);
        var skipped = results.Count(r => r.Status == FileProcessingStatus.Skipped);
        var totalDuration = TimeSpan.FromTicks(results.Sum(r => r.Duration.Ticks));

        var builder = new StringBuilder();
        builder.AppendLine("Batch Processing Summary");
        builder.AppendLine("========================");
        builder.AppendLine($"Total files:     {results.Count}");
        builder.AppendLine($"Succeeded:       {succeeded}");
        builder.AppendLine($"Failed:          {failed}");
        builder.AppendLine($"Skipped:         {skipped}");
        builder.AppendLine($"Total duration:  {totalDuration:hh\\:mm\\:ss}");
        builder.AppendLine();
        builder.AppendLine("Results:");

        foreach (var result in results)
        {
            var inputFileName = Path.GetFileName(result.InputPath);
            var outputFileName = Path.GetFileName(result.OutputPath);

            switch (result.Status)
            {
                case FileProcessingStatus.Success:
                    var languageInfo = string.IsNullOrEmpty(result.DetectedLanguage) ? "" : $"{result.DetectedLanguage}, ";
                    builder.AppendLine($"[OK]      {inputFileName} -> {outputFileName} ({languageInfo}{result.Duration:hh\\:mm\\:ss})");
                    break;

                case FileProcessingStatus.Failed:
                    builder.AppendLine($"[FAILED]  {inputFileName} -- {result.ErrorMessage}");
                    break;

                case FileProcessingStatus.Skipped:
                    builder.AppendLine($"[SKIPPED] {inputFileName} -- {result.ErrorMessage}");
                    break;
            }
        }

        return builder.ToString();
    }
}

/// <summary>
/// Represents the result of processing one file in a batch.
/// </summary>
internal sealed record FileProcessingResult(
    string InputPath,
    string OutputPath,
    FileProcessingStatus Status,
    string? ErrorMessage,
    TimeSpan Duration,
    string? DetectedLanguage);

/// <summary>
/// Lists the statuses available for batch file processing results.
/// </summary>
internal enum FileProcessingStatus
{
    Success,
    Failed,
    Skipped
}
