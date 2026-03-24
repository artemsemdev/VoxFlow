using VoxFlow.Desktop.UiTests.Infrastructure;

namespace VoxFlow.Desktop.UiTests.Pages;

internal sealed class VoxFlowDesktopApp
{
    private const string BrowseFilesSelector = "#browse-files-button";
    private const string CopyTranscriptSelector = "#copy-text-button";
    private const string BackToReadySelector = "#back-to-ready-button";
    private const string RetrySelector = "#retry-transcription-button";
    private const string ChooseDifferentFileSelector = "#choose-different-file-button";
    private const string CancelSelector = "#cancel-transcription-button";

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

    public async Task WaitForReadyAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Waiting for the Ready screen.");
        await Automation.WaitForActiveScreenAsync("ready-screen", TimeSpan.FromSeconds(45), cancellationToken);
        await Automation.WaitForVisibleElementAsync("browse-files-button", TimeSpan.FromSeconds(10), cancellationToken);
    }

    public async Task BrowseFileAsync(string filePath, CancellationToken cancellationToken)
    {
        UiProgressLogger.Write($"Starting file selection for {Path.GetFileName(filePath)}.");
        await Ready.BrowseFileAsync(filePath, cancellationToken);
    }

    internal static string BrowseButtonSelector => BrowseFilesSelector;
    internal static string CopyTranscriptButtonSelector => CopyTranscriptSelector;
    internal static string BackToReadyButtonSelector => BackToReadySelector;
    internal static string RetryButtonSelector => RetrySelector;
    internal static string ChooseDifferentFileButtonSelector => ChooseDifferentFileSelector;
    internal static string CancelButtonSelector => CancelSelector;
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
        await _automation.ClickElementAsync(VoxFlowDesktopApp.BrowseButtonSelector, cancellationToken);
        await _automation.SelectFileInOpenPanelAsync(filePath, cancellationToken);
        UiProgressLogger.Write($"Native file picker selection confirmed: {filePath}");
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
        UiProgressLogger.Write($"Waiting for Running screen for {fileName}.");
        await _automation.WaitForActiveScreenAsync("running-screen", TimeSpan.FromSeconds(45), cancellationToken);
        await _automation.WaitForVisibleElementAsync("cancel-transcription-button", TimeSpan.FromSeconds(10), cancellationToken);

        var snapshot = await _automation.GetDomSnapshotAsync(cancellationToken);
        if (!snapshot.BodyText.Contains(fileName, StringComparison.OrdinalIgnoreCase) &&
            !snapshot.BodyText.Contains("Cancel", StringComparison.OrdinalIgnoreCase))
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
        => WaitForVisibleInternalAsync(fileName, cancellationToken);

    public async Task CopyTranscriptAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Clicking Copy Transcript.");
        await _automation.ClickElementAsync(VoxFlowDesktopApp.CopyTranscriptButtonSelector, cancellationToken);
    }

    public async Task GoBackAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Returning from Complete screen back to Ready.");
        await _automation.ClickElementAsync(VoxFlowDesktopApp.BackToReadyButtonSelector, cancellationToken);
    }

    private async Task WaitForVisibleInternalAsync(string fileName, CancellationToken cancellationToken)
    {
        UiProgressLogger.Write($"Waiting for Complete screen for {fileName}.");
        await _automation.WaitForActiveScreenAsync("complete-screen", TimeSpan.FromMinutes(3), cancellationToken);
        await _automation.WaitForVisibleElementAsync("copy-text-button", TimeSpan.FromSeconds(15), cancellationToken);
        await _automation.WaitForVisibleElementAsync("open-folder-button", TimeSpan.FromSeconds(15), cancellationToken);
    }
}

internal sealed class FailedScreen
{
    private readonly MacUiAutomation _automation;

    public FailedScreen(MacUiAutomation automation)
    {
        _automation = automation;
    }

    public async Task WaitForVisibleAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Waiting for Failed screen.");
        await _automation.WaitForActiveScreenAsync("failed-screen", TimeSpan.FromMinutes(1), cancellationToken);
        await _automation.WaitForVisibleTextAsync("Transcription Failed", TimeSpan.FromSeconds(10), cancellationToken);
    }

    public async Task ChooseDifferentFileAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Clicking Choose Different File.");
        await _automation.ClickElementAsync(VoxFlowDesktopApp.ChooseDifferentFileButtonSelector, cancellationToken);
    }

    public async Task RetryAsync(CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Clicking Retry.");
        await _automation.ClickElementAsync(VoxFlowDesktopApp.RetryButtonSelector, cancellationToken);
    }
}
