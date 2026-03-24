using System.Text.RegularExpressions;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class ScenarioArtifacts : IDisposable
{
    public ScenarioArtifacts(string scenarioName)
    {
        var slug = Regex.Replace(scenarioName.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
        var timestamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");

        RootDirectory = Path.Combine(RepositoryLayout.UiArtifactsRoot, $"{timestamp}-{slug}");
        WorkingDirectory = Path.Combine(RootDirectory, "work");
        DiagnosticsDirectory = Path.Combine(RootDirectory, "diagnostics");
        AppLogPath = Path.Combine(DiagnosticsDirectory, "app.log");
        ScreenshotPath = Path.Combine(DiagnosticsDirectory, "failure.png");
        AccessibilitySnapshotPath = Path.Combine(DiagnosticsDirectory, "accessibility-snapshot.txt");

        Directory.CreateDirectory(WorkingDirectory);
        Directory.CreateDirectory(DiagnosticsDirectory);
    }

    public string RootDirectory { get; }
    public string WorkingDirectory { get; }
    public string DiagnosticsDirectory { get; }
    public string AppLogPath { get; }
    public string ScreenshotPath { get; }
    public string AccessibilitySnapshotPath { get; }

    public string WavOutputPath => Path.Combine(WorkingDirectory, "transcription.wav");
    public string ResultOutputPath => Path.Combine(WorkingDirectory, "transcription.txt");
    public string LongAudioPath => Path.Combine(WorkingDirectory, "long-input.m4a");
    public string CorruptAudioPath => Path.Combine(WorkingDirectory, "broken-input.m4a");
    public string FfmpegConcatListPath => Path.Combine(WorkingDirectory, "ffmpeg-concat.txt");

    public void Dispose()
    {
        // Keep artifacts for diagnostics after a run. Cleanup is intentionally manual.
    }
}
