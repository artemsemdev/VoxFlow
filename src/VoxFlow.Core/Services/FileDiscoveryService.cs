#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services;

/// <summary>
/// Discovers and validates input files for batch processing.
/// </summary>
internal sealed class FileDiscoveryService : IFileDiscoveryService
{
    /// <summary>
    /// Scans the configured input directory for files matching the batch file pattern.
    /// </summary>
    public IReadOnlyList<DiscoveredFile> DiscoverInputFiles(BatchOptions batchOptions)
    {
        if (!Directory.Exists(batchOptions.InputDirectory))
        {
            throw new InvalidOperationException($"Batch input directory not found: {batchOptions.InputDirectory}");
        }

        var matchingFiles = Directory.GetFiles(batchOptions.InputDirectory, batchOptions.FilePattern)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (matchingFiles.Length == 0)
        {
            throw new InvalidOperationException(
                $"No files matching '{batchOptions.FilePattern}' found in: {batchOptions.InputDirectory}");
        }

        var discoveredFiles = new List<DiscoveredFile>(matchingFiles.Length);

        foreach (var inputPath in matchingFiles)
        {
            var fileNameWithoutExtension = Path.GetFileNameWithoutExtension(inputPath);
            var outputPath = Path.Combine(batchOptions.OutputDirectory, $"{fileNameWithoutExtension}.txt");
            var tempWavPath = Path.Combine(batchOptions.TempDirectory, $"{fileNameWithoutExtension}_{Guid.NewGuid():N}.wav");

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
