using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services;
using Whisper.net;
using Xunit;

namespace VoxFlow.Core.Tests.Services;

/// <summary>
/// Cancellation and temp-WAV cleanup coverage for BatchTranscriptionService.
/// IAsyncLifetime owns the temp-dir setup/teardown so tests do not have to
/// orchestrate try/finally Delete blocks of their own (#42 acceptance).
/// </summary>
public sealed class BatchTranscriptionServiceCancellationTests : IAsyncLifetime
{
    private string _rootDir = null!;
    private string _inputDir = null!;
    private string _outputDir = null!;
    private string _tempDir = null!;
    private string _settingsPath = null!;

    public Task InitializeAsync()
    {
        _rootDir = Path.Combine(Path.GetTempPath(), $"voxflow-batch-cancel-{Guid.NewGuid():N}");
        _inputDir = Path.Combine(_rootDir, "input");
        _outputDir = Path.Combine(_rootDir, "output");
        _tempDir = Path.Combine(_rootDir, "temp");
        Directory.CreateDirectory(_inputDir);
        Directory.CreateDirectory(_outputDir);
        Directory.CreateDirectory(_tempDir);

        _settingsPath = TestSettingsFileFactory.Write(
            _rootDir,
            inputFilePath: string.Empty,
            wavFilePath: string.Empty,
            resultFilePath: string.Empty,
            modelFilePath: Path.Combine(_rootDir, "model.bin"),
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = _inputDir,
                outputDirectory = _outputDir,
                tempDirectory = _tempDir,
                filePattern = "*.m4a",
                summaryFilePath = Path.Combine(_outputDir, "summary.txt")
            });

        return Task.CompletedTask;
    }

    public Task DisposeAsync()
    {
        TryRestoreWritableMode(_tempDir);
        try
        {
            if (Directory.Exists(_rootDir))
            {
                Directory.Delete(_rootDir, recursive: true);
            }
        }
        catch
        {
            // Test temp dirs are disposable — best-effort cleanup is acceptable.
        }
        return Task.CompletedTask;
    }

    [Fact]
    public async Task TranscribeBatchAsync_CancelBetweenFiles_ReturnsPartialResults_RemainingMarkedCancelled()
    {
        // Three discovered files. AudioConversion succeeds for file 0 and trips the
        // shared CTS at the end of file 0's conversion. The loop's between-files
        // cancellation check then marks files 1 and 2 as Cancelled before they start.
        var files = BuildDiscoveredFiles("a.m4a", "b.m4a", "c.m4a");
        using var cts = new CancellationTokenSource();
        var conversion = new ScriptedAudioConversion(async (index, _, outputPath) =>
        {
            await File.WriteAllTextAsync(outputPath, "wav");
            if (index == 0)
            {
                cts.Cancel();
            }
        });
        var service = BuildService(files, conversion);

        var result = await service.TranscribeBatchAsync(
            new BatchTranscribeRequest(_inputDir, _outputDir, ConfigurationPath: _settingsPath),
            progress: null,
            cts.Token);

        Assert.Equal(3, result.TotalFiles);
        Assert.Equal(1, result.Succeeded);
        Assert.Equal(0, result.Failed);
        Assert.Equal(2, result.Skipped); // both Cancelled bucket under Skipped in the integer counters
        Assert.Equal("Success", result.Results[0].Status);
        Assert.Equal("Cancelled", result.Results[1].Status);
        Assert.Equal("Cancelled", result.Results[2].Status);
        Assert.Contains("cancelled", result.Results[1].ErrorMessage ?? string.Empty, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task TranscribeBatchAsync_CancelDuringFile_DeletesPartialTempWav()
    {
        // Two files. AudioConversion writes a partial WAV for file 0 then throws OCE
        // (simulating a cancellation mid-write). The mid-file catch must record file 0
        // as Cancelled and the temp-WAV cleanup in `finally` must remove the partial
        // file so the test directory is left empty.
        var files = BuildDiscoveredFiles("a.m4a", "b.m4a");
        var partialWavPath = files[0].TempWavPath;
        using var cts = new CancellationTokenSource();
        var conversion = new ScriptedAudioConversion(async (index, _, outputPath) =>
        {
            if (index == 0)
            {
                await File.WriteAllTextAsync(outputPath, "partial-wav");
                throw new OperationCanceledException("cancelled mid-file");
            }
            await File.WriteAllTextAsync(outputPath, "wav");
        });
        var service = BuildService(files, conversion);

        var result = await service.TranscribeBatchAsync(
            new BatchTranscribeRequest(_inputDir, _outputDir, ConfigurationPath: _settingsPath),
            progress: null,
            cts.Token);

        Assert.Equal(2, result.TotalFiles);
        Assert.Equal(0, result.Succeeded);
        Assert.Equal("Cancelled", result.Results[0].Status);
        Assert.Equal("Cancelled", result.Results[1].Status);
        Assert.False(File.Exists(partialWavPath),
            $"Partial temp WAV should have been cleaned up by the finally block; still present at {partialWavPath}.");
    }

    [Fact]
    public async Task TranscribeBatchAsync_TempWavCleanupFails_BatchCompletesWithoutPropagating()
    {
        // POSIX-only: simulate an undeletable temp WAV by writing it inside a directory
        // whose mode is then dropped to read+execute (no write). File.Delete on the
        // child raises UnauthorizedAccessException, which CleanupTempWav swallows.
        // The batch must still complete normally — cleanup failure must not poison the
        // overall result.
        if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS())
        {
            return; // chmod-style permission tricks are POSIX-only; the test asserts the swallow path.
        }

        var lockedDir = Path.Combine(_tempDir, "locked");
        Directory.CreateDirectory(lockedDir);
        var inputPath = Path.Combine(_inputDir, "demo.m4a");
        await File.WriteAllTextAsync(inputPath, "stub");
        var tempWavPath = Path.Combine(lockedDir, "demo.wav");
        var outputPath = Path.Combine(_outputDir, "demo.txt");

        var files = new List<DiscoveredFile>
        {
            new(inputPath, outputPath, tempWavPath, DiscoveryStatus.Ready, null)
        };
        var conversion = new ScriptedAudioConversion(async (_, _, wavPath) =>
        {
            await File.WriteAllTextAsync(wavPath, "wav");
            // Drop the parent dir to r-x so File.Delete on the child raises
            // UnauthorizedAccessException (the path the issue's "permission denied"
            // scenario targets). DisposeAsync restores write perms before teardown.
            // The OS check below makes the analyzer happy across the lambda boundary;
            // the test method itself returns above on non-POSIX platforms.
            if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
            {
                File.SetUnixFileMode(
                    lockedDir,
                    UnixFileMode.UserRead | UnixFileMode.UserExecute |
                    UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                    UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            }
        });
        var service = BuildService(files, conversion);

        var result = await service.TranscribeBatchAsync(
            new BatchTranscribeRequest(_inputDir, _outputDir, ConfigurationPath: _settingsPath),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Equal(1, result.TotalFiles);
        Assert.Equal(1, result.Succeeded);
        Assert.Equal(0, result.Failed);
        Assert.Equal("Success", result.Results[0].Status);
        // Cleanup failed silently; the WAV is still in the locked dir and DisposeAsync
        // will restore perms and clean up the temp tree.
        Assert.True(File.Exists(tempWavPath), "Cleanup was supposed to fail; the partial WAV should still exist.");
    }

    private List<DiscoveredFile> BuildDiscoveredFiles(params string[] fileNames)
    {
        var list = new List<DiscoveredFile>(fileNames.Length);
        foreach (var name in fileNames)
        {
            var inputPath = Path.Combine(_inputDir, name);
            var outputPath = Path.Combine(_outputDir, Path.ChangeExtension(name, ".txt"));
            var tempWavPath = Path.Combine(_tempDir, Path.ChangeExtension(name, ".wav"));
            File.WriteAllText(inputPath, "stub");
            list.Add(new DiscoveredFile(inputPath, outputPath, tempWavPath, DiscoveryStatus.Ready, null));
        }
        return list;
    }

    private BatchTranscriptionService BuildService(
        IReadOnlyList<DiscoveredFile> files,
        IAudioConversionService conversion)
    {
        return new BatchTranscriptionService(
            new StubBatchConfigurationService(_settingsPath),
            new AlwaysPassValidationService(),
            new RecordingFileDiscoveryService(files),
            conversion,
            new NullModelService(),
            new TrivialWavAudioLoader(),
            new TrivialLanguageSelectionService(),
            new TouchFileOutputWriter(),
            new RecordingBatchSummaryWriter(),
            new NullSpeakerEnrichmentService(),
            new NullVoxflowArtifactWriter());
    }

    private static void TryRestoreWritableMode(string dir)
    {
        if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS())
        {
            return;
        }
        try
        {
            if (Directory.Exists(dir))
            {
                File.SetUnixFileMode(
                    dir,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                    UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                    UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
                foreach (var sub in Directory.EnumerateDirectories(dir, "*", SearchOption.AllDirectories))
                {
                    File.SetUnixFileMode(
                        sub,
                        UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                        UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                        UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
                }
            }
        }
        catch
        {
            // Best-effort restore; DisposeAsync will surface the rmdir failure if any.
        }
    }

    private sealed class ScriptedAudioConversion(Func<int, string, string, Task> script) : IAudioConversionService
    {
        private int _index = -1;

        public Task ConvertToWavAsync(
            string inputPath,
            string outputPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            var thisIndex = Interlocked.Increment(ref _index);
            return script(thisIndex, inputPath, outputPath);
        }

        public Task<bool> ValidateFfmpegAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
            => Task.FromResult(true);
    }

    private sealed class StubBatchConfigurationService(string settingsPath) : IConfigurationService
    {
        public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
            => Task.FromResult(TranscriptionOptions.LoadFromPath(configurationPath ?? settingsPath));

        public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
            => LoadAsync(configurationPath).GetAwaiter().GetResult().SupportedLanguages;
    }

    private sealed class AlwaysPassValidationService : IValidationService
    {
        public Task<ValidationResult> ValidateAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
            => Task.FromResult(new ValidationResult(
                "PASSED",
                CanStart: true,
                HasWarnings: false,
                options.ConfigurationPath,
                [new ValidationCheck("Settings file", ValidationCheckStatus.Passed, options.ConfigurationPath)]));
    }

    private sealed class RecordingFileDiscoveryService(IReadOnlyList<DiscoveredFile> files) : IFileDiscoveryService
    {
        public IReadOnlyList<DiscoveredFile> DiscoverInputFiles(BatchOptions batchOptions, int? maxFiles = null, string outputExtension = ".txt")
            => files;
    }

    private sealed class NullModelService : IModelService
    {
        public Task<WhisperFactory> GetOrCreateFactoryAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
            => Task.FromResult<WhisperFactory>(null!);

        public ModelInfo InspectModel(TranscriptionOptions options)
            => new(options.ModelFilePath, options.ModelType, false, null, false, true);
    }

    private sealed class TrivialWavAudioLoader : IWavAudioLoader
    {
        public Task<float[]> LoadSamplesAsync(
            string wavPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
            => Task.FromResult(new float[16_000]);
    }

    private sealed class TrivialLanguageSelectionService : ILanguageSelectionService
    {
        public Task<LanguageSelectionResult> SelectBestCandidateAsync(
            WhisperFactory factory,
            float[] audioSamples,
            TranscriptionOptions options,
            IProgress<ProgressUpdate>? progress = null,
            CancellationToken cancellationToken = default)
            => Task.FromResult(new LanguageSelectionResult(
                new SupportedLanguage("en", "English", 0),
                0.9,
                TimeSpan.FromSeconds(1),
                [new FilteredSegment(TimeSpan.Zero, TimeSpan.FromSeconds(1), "hello", 0.9)],
                Array.Empty<SkippedSegment>()));
    }

    private sealed class TouchFileOutputWriter : IOutputWriter
    {
        public Task WriteAsync(
            string outputPath,
            IReadOnlyList<FilteredSegment> segments,
            TranscriptOutputContext context,
            CancellationToken cancellationToken = default)
        {
            File.WriteAllText(outputPath, "out");
            return Task.CompletedTask;
        }

        public string BuildOutputText(IReadOnlyList<FilteredSegment> segments, TranscriptOutputContext context)
            => string.Empty;
    }

    private sealed class RecordingBatchSummaryWriter : IBatchSummaryWriter
    {
        public Task WriteAsync(
            string summaryPath,
            IReadOnlyList<FileProcessingResult> results,
            CancellationToken cancellationToken = default)
            => Task.CompletedTask;
    }

    private sealed class NullSpeakerEnrichmentService : ISpeakerEnrichmentService
    {
        public Task<SpeakerEnrichmentResult> EnrichAsync(
            string wavPath,
            IReadOnlyList<FilteredSegment> segments,
            TranscriptMetadata metadata,
            SpeakerLabelingOptions options,
            IProgress<ProgressUpdate>? progress,
            CancellationToken cancellationToken)
            => Task.FromResult(SpeakerEnrichmentResult.Empty);
    }

    private sealed class NullVoxflowArtifactWriter : IVoxflowTranscriptArtifactWriter
    {
        public Task WriteAsync(
            string resultPath,
            TranscriptDocument document,
            CancellationToken cancellationToken = default)
            => Task.CompletedTask;
    }
}
