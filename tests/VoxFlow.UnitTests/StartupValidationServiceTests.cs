using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

public sealed class StartupValidationServiceTests
{
    [Fact]
    public async Task ValidateAsync_ThrowsWhenCancellationIsRequestedBeforeValidationStarts()
    {
        using var directory = new TemporaryDirectory();
        var inputPath = Path.Combine(directory.Path, "input.m4a");
        await File.WriteAllTextAsync(inputPath, "test");

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: inputPath,
            wavFilePath: Path.Combine(directory.Path, "output.wav"),
            resultFilePath: Path.Combine(directory.Path, "result.txt"),
            modelFilePath: Path.Combine(directory.Path, "model.bin"),
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        using var cancellationTokenSource = new CancellationTokenSource();
        await cancellationTokenSource.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => StartupValidationService.ValidateAsync(options, cancellationTokenSource.Token));
    }
}
