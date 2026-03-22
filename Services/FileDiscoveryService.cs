#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

/// <summary>
/// Discovers and validates input files for batch processing.
/// </summary>
internal static class FileDiscoveryService
{
    /// <summary>
    /// Scans the configured input directory for files matching the batch file pattern.
    /// </summary>
    public static IReadOnlyList<DiscoveredFile> DiscoverInputFiles(BatchOptions options)
    {
        if (!Directory.Exists(options.InputDirectory))
        {
            throw new InvalidOperationException($"Batch input directory not found: {options.InputDirectory}");
        }

        var matchingFiles = Directory.GetFiles(options.InputDirectory, options.FilePattern)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (matchingFiles.Length == 0)
        {
            throw new InvalidOperationException(
                $"No files matching '{options.FilePattern}' found in: {options.InputDirectory}");
        }

        var discoveredFiles = new List<DiscoveredFile>(matchingFiles.Length);

        foreach (var inputPath in matchingFiles)
        {
            var fileNameWithoutExtension = Path.GetFileNameWithoutExtension(inputPath);
            var outputPath = Path.Combine(options.OutputDirectory, $"{fileNameWithoutExtension}.txt");
            var tempWavPath = Path.Combine(options.TempDirectory, $"{fileNameWithoutExtension}_{Guid.NewGuid():N}.wav");

            var fileInfo = new FileInfo(inputPath);
            if (!fileInfo.Exists || fileInfo.Length == 0)
            {
                discoveredFiles.Add(new DiscoveredFile(inputPath, outputPath, tempWavPath, DiscoveryStatus.Skipped, "File is empty (0 bytes)"));
                continue;
            }

            discoveredFiles.Add(new DiscoveredFile(inputPath, outputPath, tempWavPath, DiscoveryStatus.Ready, null));
        }

        return discoveredFiles;
    }
}

/// <summary>
/// Represents one discovered input file with computed output and temp paths.
/// </summary>
internal sealed record DiscoveredFile(
    string InputPath,
    string OutputPath,
    string TempWavPath,
    DiscoveryStatus Status,
    string? SkipReason);

/// <summary>
/// Lists the discovery statuses for batch input files.
/// </summary>
internal enum DiscoveryStatus
{
    Ready,
    Skipped
}
