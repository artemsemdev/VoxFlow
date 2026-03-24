using System.Text;
using VoxFlow.Desktop.UiTests.Pages;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class DesktopUiTestSession : IAsyncDisposable
{
    private readonly DesktopUserConfigScope _userConfigScope;
    private readonly DesktopAppLauncher _launcher;
    private readonly DesktopUiAutomationBridgeClient _bridge;

    private DesktopUiTestSession(
        ScenarioArtifacts artifacts,
        DesktopUserConfigScope userConfigScope,
        DesktopAppLauncher launcher,
        DesktopUiAutomationBridgeClient bridge,
        MacUiAutomation automation,
        VoxFlowDesktopApp app)
    {
        Artifacts = artifacts;
        _userConfigScope = userConfigScope;
        _launcher = launcher;
        _bridge = bridge;
        Automation = automation;
        App = app;
    }

    public ScenarioArtifacts Artifacts { get; }
    public MacUiAutomation Automation { get; }
    public VoxFlowDesktopApp App { get; }

    public string ResultFilePath => Artifacts.ResultOutputPath;

    public static async Task<DesktopUiTestSession> StartAsync(
        string scenarioName,
        CancellationToken cancellationToken)
    {
        UiProgressLogger.Write($"Preparing Desktop UI session for scenario '{scenarioName}'.");
        ValidatePrerequisites();
        UiProgressLogger.Write("Prerequisites validated.");

        var artifacts = new ScenarioArtifacts(scenarioName);
        UiProgressLogger.Write($"Scenario artifacts directory: {artifacts.RootDirectory}");
        var userConfigScope = new DesktopUserConfigScope();
        UiProgressLogger.Write("Writing isolated Desktop user config override.");
        await userConfigScope.WriteAsync(DesktopUiTestConfigFactory.CreateValidSingleFileOverride(artifacts));
        UiProgressLogger.Write("Preparing Desktop UI automation bridge session.");
        var bridge = DesktopUiAutomationBridgeClient.CreateAndPrepare();

        UiProgressLogger.Write("Launching real VoxFlow.Desktop app.");
        var launcher = await DesktopAppLauncher.StartAsync(artifacts.AppLogPath, cancellationToken);
        var automation = new MacUiAutomation(launcher.ProcessName, bridge);

        try
        {
            UiProgressLogger.Write("Waiting for the Desktop UI process to appear.");
            await automation.WaitForProcessAsync(TimeSpan.FromSeconds(30), cancellationToken);
            UiProgressLogger.Write("Checking macOS Accessibility access.");
            await automation.EnsureAccessibilityAccessAsync(cancellationToken);
            UiProgressLogger.Write("Waiting for the Desktop main window.");
            await automation.WaitForMainWindowAsync(TimeSpan.FromSeconds(45), cancellationToken);
            UiProgressLogger.Write("Waiting for the Desktop webview automation bridge.");
            await bridge.WaitForReadyAsync(TimeSpan.FromSeconds(30), cancellationToken);
        }
        catch
        {
            await launcher.DisposeAsync();
            await bridge.DisposeAsync();
            await userConfigScope.DisposeAsync();
            artifacts.Dispose();
            throw;
        }

        var app = new VoxFlowDesktopApp(automation);
        UiProgressLogger.Write($"Desktop UI session is ready. App log: {artifacts.AppLogPath}");
        return new DesktopUiTestSession(artifacts, userConfigScope, launcher, bridge, automation, app);
    }

    public Task RewriteUserConfigAsync(System.Text.Json.Nodes.JsonObject root)
        => _userConfigScope.WriteAsync(root);

    public async Task<string> CreateLongAudioAsync(string inputPath, CancellationToken cancellationToken)
        => await TestAudioFactory.CreateLongAudioAsync(inputPath, Artifacts, cancellationToken);

    public async Task<string> CreateCorruptAudioAsync(CancellationToken cancellationToken)
        => await TestAudioFactory.CreateCorruptAudioAsync(Artifacts, cancellationToken);

    public async Task<string> CaptureFailureDiagnosticsAsync(Exception exception, CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Capturing failure diagnostics.");
        var builder = new StringBuilder();
        builder.AppendLine(exception.ToString());
        builder.AppendLine();
        builder.AppendLine($"App log: {Artifacts.AppLogPath}");
        builder.AppendLine($"Screenshot: {Artifacts.ScreenshotPath}");
        builder.AppendLine($"Accessibility snapshot: {Artifacts.AccessibilitySnapshotPath}");

        try
        {
            await Automation.CaptureScreenshotAsync(Artifacts.ScreenshotPath, cancellationToken);
        }
        catch (Exception screenshotError)
        {
            builder.AppendLine();
            builder.AppendLine($"Screenshot capture failed: {screenshotError.Message}");
        }

        try
        {
            var snapshot = await Automation.GetAccessibilitySnapshotAsync(cancellationToken);
            await File.WriteAllTextAsync(Artifacts.AccessibilitySnapshotPath, snapshot, cancellationToken);
        }
        catch (Exception snapshotError)
        {
            builder.AppendLine();
            builder.AppendLine($"Accessibility snapshot capture failed: {snapshotError.Message}");
        }

        return builder.ToString().Trim();
    }

    public async ValueTask DisposeAsync()
    {
        await _launcher.DisposeAsync();
        await _bridge.DisposeAsync();
        await _userConfigScope.DisposeAsync();
        Artifacts.Dispose();
    }

    private static void ValidatePrerequisites()
    {
        if (!File.Exists(RepositoryLayout.DesktopExecutablePath))
        {
            throw new FileNotFoundException(
                "The VoxFlow Desktop executable was not found. Build src/VoxFlow.Desktop first.",
                RepositoryLayout.DesktopExecutablePath);
        }

        if (!File.Exists(RepositoryLayout.InputFileOne))
        {
            throw new FileNotFoundException(
                "The sample input file for UI tests is missing.",
                RepositoryLayout.InputFileOne);
        }

        if (!File.Exists(RepositoryLayout.InputFileTwo))
        {
            throw new FileNotFoundException(
                "The second sample input file for UI tests is missing.",
                RepositoryLayout.InputFileTwo);
        }

        if (!File.Exists(RepositoryLayout.ModelFile))
        {
            throw new FileNotFoundException(
                "The Whisper model file is missing. Place the model at models/ggml-base.bin before running UI tests.",
                RepositoryLayout.ModelFile);
        }
    }
}
