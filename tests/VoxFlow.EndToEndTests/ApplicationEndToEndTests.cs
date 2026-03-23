using System;
using System.IO;
using System.Threading.Tasks;
using Xunit;

public sealed class ApplicationEndToEndTests
{
    [Fact]
    public async Task Run_FailsDuringStartupValidation_WhenInputFileIsMissing()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: Path.Combine(directory.Path, "missing.m4a"),
            wavFilePath: Path.Combine(directory.Path, "test.wav"),
            resultFilePath: Path.Combine(directory.Path, "result.txt"),
            modelFilePath: Path.Combine(directory.Path, "models", "ggml-base.bin"),
            ffmpegExecutablePath: "ffmpeg",
            startupValidation: new
            {
                enabled = true,
                printDetailedReport = true,
                checkInputFile = true,
                checkOutputDirectories = true,
                checkOutputWriteAccess = true,
                checkFfmpegAvailability = false,
                checkModelType = false,
                checkModelDirectory = false,
                checkModelLoadability = false,
                checkLanguageSupport = false,
                checkWhisperRuntime = false
            });

        var result = await TestProcessRunner.RunAppAsync(settingsPath, TimeSpan.FromSeconds(60));

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("=== Startup Validation ===", result.Output, StringComparison.Ordinal);
        Assert.Contains("Startup validation outcome: FAILED", result.Output, StringComparison.Ordinal);
        Assert.Contains("Transcription will not start", result.Output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Run_PassesStartupValidation_AndPreparesAudioWithoutCheckedInModel()
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
            });

        var result = await TestProcessRunner.RunAppUntilOutputAsync(
            settingsPath,
            TimeSpan.FromSeconds(30),
            "WAV conversion succeeded.");

        Assert.Contains("Startup validation outcome: PASSED", result.Output, StringComparison.Ordinal);
        Assert.True(result.Output.Contains("Starting transcription...", StringComparison.Ordinal), result.Output);
        Assert.Contains("WAV conversion succeeded.", result.Output, StringComparison.Ordinal);
        Assert.True(File.Exists(wavPath), $"Expected WAV file to exist at {wavPath}");
    }
}
