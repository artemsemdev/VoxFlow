using VoxFlow.Desktop.UiTests.Infrastructure;

namespace VoxFlow.Desktop.UiTests.Pages;

internal sealed class VoxFlowDesktopApp
{
    private static readonly IReadOnlyList<string> BrowseFilesLabels = ["Browse Files", "+ Browse Files"];

    public VoxFlowDesktopApp(MacUiAutomation automation)
    {
        Automation = automation;
        Ready = new ReadyScreen(automation);
        Running = new RunningScreen(automation);
        Complete = new CompleteScreen(automation);
        Failed = new FailedScreen(automation);
    }

    public MacUiAutomation Automation { get; }
    public ReadyScreen Ready { get; }
    public RunningScreen Running { get; }
    public CompleteScreen Complete { get; }
    public FailedScreen Failed { get; }

    public Task WaitForReadyAsync(CancellationToken cancellationToken)
        => Automation.WaitForVisibleTextAsync("Audio Transcription", TimeSpan.FromSeconds(45), cancellationToken);

    public Task BrowseFileAsync(string filePath, CancellationToken cancellationToken)
        => Ready.BrowseFileAsync(filePath, cancellationToken);

    internal static IReadOnlyList<string> BrowseButtonLabels => BrowseFilesLabels;
}

internal sealed class ReadyScreen
{
    private readonly MacUiAutomation _automation;

    public ReadyScreen(MacUiAutomation automation)
    {
        _automation = automation;
    }

    public async Task BrowseFileAsync(string filePath, CancellationToken cancellationToken)
    {
        await _automation.ClickButtonAsync(VoxFlowDesktopApp.BrowseButtonLabels, cancellationToken);
        await _automation.SelectFileInOpenPanelAsync(filePath, cancellationToken);
    }
}

internal sealed class RunningScreen
{
    private readonly MacUiAutomation _automation;

    public RunningScreen(MacUiAutomation automation)
    {
        _automation = automation;
    }

    public async Task WaitForVisibleAsync(string fileName, CancellationToken cancellationToken)
    {
        await _automation.WaitForAnyVisibleTextAsync(
            ["Cancel", fileName, "Transcribing", "Converting audio"],
            TimeSpan.FromSeconds(45),
            cancellationToken);

        var snapshot = await _automation.GetAccessibilitySnapshotAsync(cancellationToken);
        if (!snapshot.Contains("Cancel", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "The running screen never exposed the Cancel action. Progress/status UI was not observed.");
        }
    }
}

internal sealed class CompleteScreen
{
    private readonly MacUiAutomation _automation;

    public CompleteScreen(MacUiAutomation automation)
    {
        _automation = automation;
    }

    public Task WaitForVisibleAsync(string fileName, CancellationToken cancellationToken)
        => _automation.WaitForAnyVisibleTextAsync(
            [fileName, "Copy Text", "Open Folder"],
            TimeSpan.FromMinutes(3),
            cancellationToken);

    public Task CopyTranscriptAsync(CancellationToken cancellationToken)
        => _automation.ClickButtonAsync(["Copy Transcript", "Copy Text"], cancellationToken);

    public Task GoBackAsync(CancellationToken cancellationToken)
        => _automation.ClickButtonAsync(["Back To Ready Screen", "‹"], cancellationToken);
}

internal sealed class FailedScreen
{
    private readonly MacUiAutomation _automation;

    public FailedScreen(MacUiAutomation automation)
    {
        _automation = automation;
    }

    public Task WaitForVisibleAsync(CancellationToken cancellationToken)
        => _automation.WaitForVisibleTextAsync("Transcription Failed", TimeSpan.FromMinutes(1), cancellationToken);

    public Task ChooseDifferentFileAsync(CancellationToken cancellationToken)
        => _automation.ClickButtonAsync(["Choose Different File"], cancellationToken);

    public Task RetryAsync(CancellationToken cancellationToken)
        => _automation.ClickButtonAsync(["Retry Transcription", "Retry"], cancellationToken);
}
