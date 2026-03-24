using Xunit;
using Xunit.Sdk;
using VoxFlow.Desktop.UiTests.Infrastructure;

namespace VoxFlow.Desktop.UiTests;

public sealed class DesktopEndToEndTests
{
    [DesktopUiFact]
    public Task AppStartsSuccessfully_AndReadyScreenIsVisible()
        => RunScenarioAsync(
            "app-starts-successfully",
            async (session, cancellationToken) =>
            {
                await session.App.WaitForReadyAsync(cancellationToken);
                var snapshot = await session.Automation.GetAccessibilitySnapshotAsync(cancellationToken);
                Assert.Contains("Audio Transcription", snapshot, StringComparison.OrdinalIgnoreCase);
                Assert.Contains("ready-screen", snapshot, StringComparison.OrdinalIgnoreCase);
                Assert.Contains("browse-files-button", snapshot, StringComparison.OrdinalIgnoreCase);
            });

    [DesktopUiFact]
    public Task HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult()
        => RunScenarioAsync(
            "happy-path-process-single-file",
            async (session, cancellationToken) =>
            {
                var longAudioPath = await session.CreateLongAudioAsync(RepositoryLayout.InputFileOne, cancellationToken);

                await session.App.WaitForReadyAsync(cancellationToken);
                await session.App.BrowseFileAsync(longAudioPath, cancellationToken);
                await session.App.Running.WaitForVisibleAsync(Path.GetFileName(longAudioPath), cancellationToken);
                await session.App.Complete.WaitForVisibleAsync(Path.GetFileName(longAudioPath), cancellationToken);

                Assert.True(File.Exists(session.ResultFilePath), $"Expected result file to exist: {session.ResultFilePath}");

                var resultText = await File.ReadAllTextAsync(session.ResultFilePath, cancellationToken);
                Assert.False(string.IsNullOrWhiteSpace(resultText));
            });

    [DesktopUiFact]
    public Task ResultScreen_CopyText_CopiesTranscriptToClipboard()
        => RunScenarioAsync(
            "copy-transcript-to-clipboard",
            async (session, cancellationToken) =>
            {
                await session.App.WaitForReadyAsync(cancellationToken);
                await session.App.BrowseFileAsync(RepositoryLayout.InputFileOne, cancellationToken);
                await session.App.Complete.WaitForVisibleAsync(Path.GetFileName(RepositoryLayout.InputFileOne), cancellationToken);

                await session.App.Complete.CopyTranscriptAsync(cancellationToken);
                await session.Automation.WaitForVisibleTextAsync("Copied!", TimeSpan.FromSeconds(10), cancellationToken);

                var clipboardText = await session.Automation.GetClipboardTextAsync(cancellationToken);
                Assert.False(string.IsNullOrWhiteSpace(clipboardText));
            });

    [DesktopUiFact]
    public Task InvalidAudio_ShowsFailure_AndUserCanRecoverByChoosingAnotherFile()
        => RunScenarioAsync(
            "invalid-audio-failure-and-recovery",
            async (session, cancellationToken) =>
            {
                var corruptAudioPath = await session.CreateCorruptAudioAsync(cancellationToken);

                await session.App.WaitForReadyAsync(cancellationToken);
                await session.App.BrowseFileAsync(corruptAudioPath, cancellationToken);
                await session.App.Failed.WaitForVisibleAsync(cancellationToken);

                var failureSnapshot = await session.Automation.GetAccessibilitySnapshotAsync(cancellationToken);
                Assert.Contains("Transcription Failed", failureSnapshot, StringComparison.OrdinalIgnoreCase);
                Assert.Contains("failed-screen", failureSnapshot, StringComparison.OrdinalIgnoreCase);

                await session.App.Failed.ChooseDifferentFileAsync(cancellationToken);
                await session.App.WaitForReadyAsync(cancellationToken);

                await session.App.BrowseFileAsync(RepositoryLayout.InputFileTwo, cancellationToken);
                await session.App.Complete.WaitForVisibleAsync(Path.GetFileName(RepositoryLayout.InputFileTwo), cancellationToken);

                Assert.True(File.Exists(session.ResultFilePath), $"Expected result file to exist after recovery: {session.ResultFilePath}");
            });

    [DesktopUiFact]
    public Task RepeatedUsage_UserCanProcessTwoFilesSequentially()
        => RunScenarioAsync(
            "repeated-usage-two-files-sequentially",
            async (session, cancellationToken) =>
            {
                await session.App.WaitForReadyAsync(cancellationToken);

                await session.App.BrowseFileAsync(RepositoryLayout.InputFileOne, cancellationToken);
                await session.App.Complete.WaitForVisibleAsync(Path.GetFileName(RepositoryLayout.InputFileOne), cancellationToken);

                var firstWriteUtc = File.GetLastWriteTimeUtc(session.ResultFilePath);

                await session.App.Complete.GoBackAsync(cancellationToken);
                await session.App.WaitForReadyAsync(cancellationToken);

                await session.App.BrowseFileAsync(RepositoryLayout.InputFileTwo, cancellationToken);
                await session.App.Complete.WaitForVisibleAsync(Path.GetFileName(RepositoryLayout.InputFileTwo), cancellationToken);

                var secondWriteUtc = File.GetLastWriteTimeUtc(session.ResultFilePath);
                Assert.True(
                    secondWriteUtc >= firstWriteUtc,
                    $"Expected the result file to be updated on the second run. First={firstWriteUtc:O}, second={secondWriteUtc:O}");
            });

    private static async Task RunScenarioAsync(
        string scenarioName,
        Func<DesktopUiTestSession, CancellationToken, Task> scenario)
    {
        using var cancellationSource = new CancellationTokenSource(TimeSpan.FromMinutes(6));
        var startedAt = DateTimeOffset.UtcNow;
        UiProgressLogger.Write($"Scenario started: {scenarioName}");
        await using var session = await DesktopUiTestSession.StartAsync(scenarioName, cancellationSource.Token);

        try
        {
            await scenario(session, cancellationSource.Token);
            UiProgressLogger.Write(
                $"Scenario finished successfully: {scenarioName} (elapsed {(DateTimeOffset.UtcNow - startedAt).TotalSeconds:F1}s)");
        }
        catch (Exception ex)
        {
            UiProgressLogger.Write($"Scenario failed: {scenarioName} ({ex.GetType().Name}: {ex.Message})");
            var diagnostics = await session.CaptureFailureDiagnosticsAsync(ex, CancellationToken.None);
            throw new XunitException(diagnostics);
        }
    }
}
