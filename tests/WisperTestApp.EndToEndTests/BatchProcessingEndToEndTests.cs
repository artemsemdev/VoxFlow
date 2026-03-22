using System;
using System.IO;
using System.Threading.Tasks;
using Xunit;

public sealed class BatchProcessingEndToEndTests
{
    [Fact]
    public async Task Run_SingleMode_SingleFileBehaviorUnchanged()
    {
        using var directory = new TemporaryDirectory();
        var inputPath = Path.Combine(directory.Path, "input.m4a");
        var preparedWavPath = Path.Combine(directory.Path, "prepared.wav");
        var wavPath = Path.Combine(directory.Path, "output.wav");
        var resultPath = Path.Combine(directory.Path, "result.txt");
        var modelPath = Path.Combine(directory.Path, "models", "ggml-base.bin");

        await File.WriteAllTextAsync(inputPath, "placeholder");
        TestWaveFileFactory.CreatePcm16MonoWave(preparedWavPath, 16000, [0, 0, 0, 0, 0, 0, 0, 0]);
        Directory.CreateDirectory(Path.GetDirectoryName(modelPath)!);

        var fakeFfmpegPath = FakeFfmpegFactory.Create(directory.Path, preparedWavPath);
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: inputPath,
            wavFilePath: wavPath,
            resultFilePath: resultPath,
            modelFilePath: modelPath,
            ffmpegExecutablePath: fakeFfmpegPath,
            supportedLanguages: [("en", "English")],
            startupValidation: new
            {
                enabled = true,
                printDetailedReport = true,
                checkInputFile = true,
                checkOutputDirectories = true,
                checkOutputWriteAccess = true,
                checkFfmpegAvailability = true,
                checkModelType = true,
                checkModelDirectory = true,
                checkModelLoadability = false,
                checkLanguageSupport = false,
                checkWhisperRuntime = false
            },
            processingMode: "single");

        var result = await TestProcessRunner.RunAppUntilOutputAsync(
            settingsPath,
            TimeSpan.FromSeconds(30),
            "WAV conversion succeeded.");

        Assert.Contains("Starting transcription...", result.Output, StringComparison.Ordinal);
        Assert.Contains("WAV conversion succeeded.", result.Output, StringComparison.Ordinal);
        Assert.DoesNotContain("batch processing", result.Output, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Run_BatchWithMissingInputDirectory_FailsStartupValidation()
    {
        using var directory = new TemporaryDirectory();
        var missingInputDir = Path.Combine(directory.Path, "missing-input");
        var outputDir = Path.Combine(directory.Path, "output");
        Directory.CreateDirectory(outputDir);

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "",
            wavFilePath: "",
            resultFilePath: "",
            modelFilePath: Path.Combine(directory.Path, "models", "ggml-base.bin"),
            ffmpegExecutablePath: "ffmpeg",
            startupValidation: new
            {
                enabled = true,
                printDetailedReport = true,
                checkInputFile = true,
                checkOutputDirectories = false,
                checkOutputWriteAccess = false,
                checkFfmpegAvailability = false,
                checkModelType = false,
                checkModelDirectory = false,
                checkModelLoadability = false,
                checkLanguageSupport = false,
                checkWhisperRuntime = false
            },
            processingMode: "batch",
            batch: new
            {
                inputDirectory = missingInputDir,
                outputDirectory = outputDir,
                filePattern = "*.m4a",
                summaryFilePath = Path.Combine(directory.Path, "summary.txt")
            });

        var result = await TestProcessRunner.RunAppAsync(settingsPath, TimeSpan.FromSeconds(60));

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("FAILED", result.Output, StringComparison.Ordinal);
        Assert.Contains("Batch input directory", result.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Run_BatchWithValidDirectory_ProcessesFiles()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        var tempDir = Path.Combine(directory.Path, "temp");
        var modelDir = Path.Combine(directory.Path, "models");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(tempDir);
        Directory.CreateDirectory(modelDir);

        // Create two input files
        File.WriteAllText(Path.Combine(inputDir, "file1.m4a"), "placeholder audio 1");
        File.WriteAllText(Path.Combine(inputDir, "file2.m4a"), "placeholder audio 2");

        // Create a prepared WAV for fake ffmpeg to copy
        var preparedWavPath = Path.Combine(directory.Path, "prepared.wav");
        TestWaveFileFactory.CreatePcm16MonoWave(preparedWavPath, 16000, [0, 0, 0, 0, 0, 0, 0, 0]);

        var fakeFfmpegPath = FakeFfmpegFactory.Create(directory.Path, preparedWavPath);
        var summaryPath = Path.Combine(directory.Path, "batch-summary.txt");

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "",
            wavFilePath: "",
            resultFilePath: "",
            modelFilePath: Path.Combine(modelDir, "ggml-base.bin"),
            ffmpegExecutablePath: fakeFfmpegPath,
            supportedLanguages: [("en", "English")],
            startupValidation: new
            {
                enabled = true,
                printDetailedReport = true,
                checkInputFile = true,
                checkOutputDirectories = false,
                checkOutputWriteAccess = false,
                checkFfmpegAvailability = true,
                checkModelType = true,
                checkModelDirectory = true,
                checkModelLoadability = false,
                checkLanguageSupport = false,
                checkWhisperRuntime = false
            },
            processingMode: "batch",
            batch: new
            {
                inputDirectory = inputDir,
                outputDirectory = outputDir,
                tempDirectory = tempDir,
                filePattern = "*.m4a",
                stopOnFirstError = false,
                keepIntermediateFiles = false,
                summaryFilePath = summaryPath
            });

        // Run until we see batch processing start and file discovery
        var result = await TestProcessRunner.RunAppUntilOutputAsync(
            settingsPath,
            TimeSpan.FromSeconds(30),
            "Discovered 2 file(s)");

        Assert.Contains("Starting batch processing...", result.Output, StringComparison.Ordinal);
        Assert.Contains("Discovered 2 file(s)", result.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Run_BatchWithNoMatchingFiles_FailsWithDiagnostics()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);

        // Only a .txt file, no .m4a files
        File.WriteAllText(Path.Combine(inputDir, "readme.txt"), "not audio");

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "",
            wavFilePath: "",
            resultFilePath: "",
            modelFilePath: Path.Combine(directory.Path, "models", "ggml-base.bin"),
            ffmpegExecutablePath: "ffmpeg",
            startupValidation: new
            {
                enabled = true,
                printDetailedReport = true,
                checkInputFile = true,
                checkOutputDirectories = false,
                checkOutputWriteAccess = false,
                checkFfmpegAvailability = false,
                checkModelType = false,
                checkModelDirectory = false,
                checkModelLoadability = false,
                checkLanguageSupport = false,
                checkWhisperRuntime = false
            },
            processingMode: "batch",
            batch: new
            {
                inputDirectory = inputDir,
                outputDirectory = outputDir,
                filePattern = "*.m4a",
                summaryFilePath = Path.Combine(directory.Path, "summary.txt")
            });

        var result = await TestProcessRunner.RunAppAsync(settingsPath, TimeSpan.FromSeconds(60));

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("FAILED", result.Output, StringComparison.Ordinal);
        Assert.Contains("No files matching", result.Output, StringComparison.Ordinal);
    }
}
