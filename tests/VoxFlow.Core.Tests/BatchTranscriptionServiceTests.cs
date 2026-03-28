using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services;
using Whisper.net;
using Xunit;

namespace VoxFlow.Core.Tests;

public sealed class BatchTranscriptionServiceTests
{
    [Fact]
    public async Task TranscribeBatchAsync_ForwardsMaxFilesToDiscovery()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        var tempDir = Path.Combine(directory.Path, "temp");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(tempDir);

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: string.Empty,
            wavFilePath: string.Empty,
            resultFilePath: string.Empty,
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = inputDir,
                outputDirectory = outputDir,
                tempDirectory = tempDir,
                filePattern = "*.m4a",
                summaryFilePath = Path.Combine(outputDir, "summary.txt")
            });

        var discovery = new RecordingFileDiscoveryService(
            [
                new DiscoveredFile(
                    Path.Combine(inputDir, "empty.m4a"),
                    Path.Combine(outputDir, "empty.txt"),
                    Path.Combine(tempDir, "empty.wav"),
                    DiscoveryStatus.Skipped,
                    "Skipped for test")
            ]);

        var service = new BatchTranscriptionService(
            new StubBatchConfigurationService(settingsPath),
            new StubBatchValidationService(),
            discovery,
            new NoOpAudioConversionService(),
            new NoOpModelService(),
            new NoOpWavAudioLoader(),
            new NoOpLanguageSelectionService(),
            new NoOpOutputWriter(),
            new RecordingBatchSummaryWriter());

        var result = await service.TranscribeBatchAsync(
            new BatchTranscribeRequest(inputDir, outputDir, MaxFiles: 1, ConfigurationPath: settingsPath));

        Assert.Equal(1, discovery.RecordedMaxFiles);
        Assert.Single(result.Results);
        Assert.Equal("Skipped", result.Results[0].Status);
    }

    [Fact]
    public async Task TranscribeBatchAsync_ReportsNestedProgress_ForCurrentFile()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        var tempDir = Path.Combine(directory.Path, "temp");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(tempDir);

        var inputPath = Path.Combine(inputDir, "demo.m4a");
        var outputPath = Path.Combine(outputDir, "demo.txt");
        var tempWavPath = Path.Combine(tempDir, "demo.wav");
        File.WriteAllText(inputPath, "stub");

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: string.Empty,
            wavFilePath: string.Empty,
            resultFilePath: string.Empty,
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = inputDir,
                outputDirectory = outputDir,
                tempDirectory = tempDir,
                filePattern = "*.m4a",
                summaryFilePath = Path.Combine(outputDir, "summary.txt")
            });

        var discovery = new RecordingFileDiscoveryService(
            [
                new DiscoveredFile(
                    inputPath,
                    outputPath,
                    tempWavPath,
                    DiscoveryStatus.Ready,
                    null)
            ]);
        var progressUpdates = new List<ProgressUpdate>();
        var progress = new Progress<ProgressUpdate>(update => progressUpdates.Add(update));

        var service = new BatchTranscriptionService(
            new StubBatchConfigurationService(settingsPath),
            new StubBatchValidationService(),
            discovery,
            new SuccessfulAudioConversionService(),
            new NoOpModelService(),
            new SuccessfulWavAudioLoader(),
            new ReportingLanguageSelectionService(),
            new RecordingOutputWriter(),
            new RecordingBatchSummaryWriter());

        var result = await service.TranscribeBatchAsync(
            new BatchTranscribeRequest(inputDir, outputDir, ConfigurationPath: settingsPath),
            progress);

        Assert.Single(result.Results);
        Assert.Equal("Success", result.Results[0].Status);
        Assert.Contains(
            progressUpdates,
            update => update.Stage == ProgressStage.Transcribing &&
                      update.PercentComplete > 10 &&
                      update.PercentComplete < 90 &&
                      update.Message is not null &&
                      update.Message.Contains("[1/1] demo.m4a", StringComparison.Ordinal) &&
                      update.Message.Contains("Transcribing English", StringComparison.Ordinal));
    }

    private sealed class StubBatchConfigurationService(string settingsPath) : IConfigurationService
    {
        public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
            => Task.FromResult(TranscriptionOptions.LoadFromPath(configurationPath ?? settingsPath));

        public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
            => LoadAsync(configurationPath).GetAwaiter().GetResult().SupportedLanguages;
    }

    private sealed class RecordingFileDiscoveryService(IReadOnlyList<DiscoveredFile> files) : IFileDiscoveryService
    {
        public int? RecordedMaxFiles { get; private set; }

        public IReadOnlyList<DiscoveredFile> DiscoverInputFiles(BatchOptions batchOptions, int? maxFiles = null)
        {
            RecordedMaxFiles = maxFiles;
            return files;
        }
    }

    private sealed class StubBatchValidationService : IValidationService
    {
        public Task<ValidationResult> ValidateAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            var result = new ValidationResult(
                "PASSED",
                true,
                false,
                options.ConfigurationPath,
                [new ValidationCheck("Settings file", ValidationCheckStatus.Passed, options.ConfigurationPath)]);

            return Task.FromResult(result);
        }
    }

    private sealed class NoOpAudioConversionService : IAudioConversionService
    {
        public Task ConvertToWavAsync(
            string inputPath,
            string outputPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            throw new NotSupportedException("Skipped files should not trigger audio conversion.");
        }

        public Task<bool> ValidateFfmpegAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            throw new NotSupportedException("Validation is stubbed for this test.");
        }
    }

    private sealed class SuccessfulAudioConversionService : IAudioConversionService
    {
        public Task ConvertToWavAsync(
            string inputPath,
            string outputPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            File.WriteAllText(outputPath, "wav");
            return Task.CompletedTask;
        }

        public Task<bool> ValidateFfmpegAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
            => Task.FromResult(true);
    }

    private sealed class NoOpModelService : IModelService
    {
        public Task<WhisperFactory> GetOrCreateFactoryAsync(
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult<WhisperFactory>(null!);
        }

        public ModelInfo InspectModel(TranscriptionOptions options)
            => new(options.ModelFilePath, options.ModelType, false, null, false, true);
    }

    private sealed class NoOpWavAudioLoader : IWavAudioLoader
    {
        public Task<float[]> LoadSamplesAsync(
            string wavPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            throw new NotSupportedException("Skipped files should not load WAV data.");
        }
    }

    private sealed class SuccessfulWavAudioLoader : IWavAudioLoader
    {
        public Task<float[]> LoadSamplesAsync(
            string wavPath,
            TranscriptionOptions options,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new float[160_000]);
        }
    }

    private sealed class NoOpLanguageSelectionService : ILanguageSelectionService
    {
        public Task<LanguageSelectionResult> SelectBestCandidateAsync(
            WhisperFactory factory,
            float[] audioSamples,
            TranscriptionOptions options,
            IProgress<ProgressUpdate>? progress = null,
            CancellationToken cancellationToken = default)
        {
            throw new NotSupportedException("Skipped files should not run language selection.");
        }
    }

    private sealed class ReportingLanguageSelectionService : ILanguageSelectionService
    {
        public Task<LanguageSelectionResult> SelectBestCandidateAsync(
            WhisperFactory factory,
            float[] audioSamples,
            TranscriptionOptions options,
            IProgress<ProgressUpdate>? progress = null,
            CancellationToken cancellationToken = default)
        {
            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing,
                25,
                TimeSpan.Zero,
                "Transcribing English",
                "English"));
            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing,
                75,
                TimeSpan.Zero,
                "Transcribing English",
                "English"));

            return Task.FromResult(new LanguageSelectionResult(
                new SupportedLanguage("en", "English", 0),
                0.8,
                TimeSpan.FromSeconds(10),
                [new FilteredSegment(TimeSpan.Zero, TimeSpan.FromSeconds(2), "hello", 0.9)],
                Array.Empty<SkippedSegment>()));
        }
    }

    private sealed class NoOpOutputWriter : IOutputWriter
    {
        public Task WriteAsync(
            string outputPath,
            IReadOnlyList<FilteredSegment> segments,
            CancellationToken cancellationToken = default)
        {
            throw new NotSupportedException("Skipped files should not write transcripts.");
        }

        public string BuildOutputText(IReadOnlyList<FilteredSegment> segments)
            => string.Empty;
    }

    private sealed class RecordingOutputWriter : IOutputWriter
    {
        public Task WriteAsync(
            string outputPath,
            IReadOnlyList<FilteredSegment> segments,
            CancellationToken cancellationToken = default)
        {
            File.WriteAllText(outputPath, string.Join(Environment.NewLine, segments.Select(segment => segment.Text)));
            return Task.CompletedTask;
        }

        public string BuildOutputText(IReadOnlyList<FilteredSegment> segments)
            => string.Join(Environment.NewLine, segments.Select(segment => segment.Text));
    }

    private sealed class RecordingBatchSummaryWriter : IBatchSummaryWriter
    {
        public Task WriteAsync(
            string summaryPath,
            IReadOnlyList<FileProcessingResult> results,
            CancellationToken cancellationToken = default)
        {
            return Task.CompletedTask;
        }
    }
}
