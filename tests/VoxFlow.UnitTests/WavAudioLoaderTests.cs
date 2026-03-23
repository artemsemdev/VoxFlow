using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

public sealed class WavAudioLoaderTests
{
    [Fact]
    public async Task LoadSamplesAsync_ReadsPcm16WaveFile()
    {
        using var directory = new TemporaryDirectory();
        var wavPath = Path.Combine(directory.Path, "input.wav");
        TestWaveFileFactory.CreatePcm16MonoWave(wavPath, 16000, [0, 16384, -16384]);

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: wavPath,
            resultFilePath: Path.Combine(directory.Path, "result.txt"),
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        var samples = await WavAudioLoader.LoadSamplesAsync(wavPath, options);

        Assert.Equal(3, samples.Length);
        Assert.Equal(0f, samples[0], 4);
        Assert.Equal(0.5f, samples[1], 3);
        Assert.Equal(-0.5f, samples[2], 3);
    }

    [Fact]
    public async Task LoadSamplesAsync_RejectsUnexpectedSampleRate()
    {
        using var directory = new TemporaryDirectory();
        var wavPath = Path.Combine(directory.Path, "input.wav");
        TestWaveFileFactory.CreatePcm16MonoWave(wavPath, 8000, [0, 1, 2]);

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: wavPath,
            resultFilePath: Path.Combine(directory.Path, "result.txt"),
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => WavAudioLoader.LoadSamplesAsync(wavPath, options));

        Assert.Contains("Expected 1 channel(s) at 16000 Hz", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task LoadSamplesAsync_ThrowsWhenCancellationIsRequestedBeforeReading()
    {
        using var directory = new TemporaryDirectory();
        var wavPath = Path.Combine(directory.Path, "input.wav");
        TestWaveFileFactory.CreatePcm16MonoWave(wavPath, 16000, [0, 16384, -16384]);

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: wavPath,
            resultFilePath: Path.Combine(directory.Path, "result.txt"),
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        using var cancellationTokenSource = new CancellationTokenSource();
        await cancellationTokenSource.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => WavAudioLoader.LoadSamplesAsync(wavPath, options, cancellationTokenSource.Token));
    }
}
