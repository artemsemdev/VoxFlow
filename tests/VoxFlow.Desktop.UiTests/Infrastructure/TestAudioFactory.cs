namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal static class TestAudioFactory
{
    public static async Task<string> CreateLongAudioAsync(
        string inputPath,
        ScenarioArtifacts artifacts,
        CancellationToken cancellationToken)
    {
        var escapedPath = inputPath.Replace("'", "'\\''", StringComparison.Ordinal);
        var lines = Enumerable.Repeat($"file '{escapedPath}'", 6);
        await File.WriteAllLinesAsync(artifacts.FfmpegConcatListPath, lines, cancellationToken);

        await CommandRunner.RunCheckedAsync(
            "ffmpeg",
            [
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", artifacts.FfmpegConcatListPath,
                "-c:a", "aac",
                "-b:a", "128k",
                artifacts.LongAudioPath
            ],
            cancellationToken: cancellationToken,
            timeout: TimeSpan.FromMinutes(2));

        return artifacts.LongAudioPath;
    }

    public static async Task<string> CreateCorruptAudioAsync(
        ScenarioArtifacts artifacts,
        CancellationToken cancellationToken)
    {
        await File.WriteAllTextAsync(
            artifacts.CorruptAudioPath,
            "This is not a valid audio file but uses an .m4a extension to exercise failure handling.",
            cancellationToken);
        return artifacts.CorruptAudioPath;
    }
}
