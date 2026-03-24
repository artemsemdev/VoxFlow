using System.Runtime.InteropServices;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal static class RepositoryLayout
{
    private static readonly Lazy<string> RepositoryRootPath = new(FindRepositoryRoot);

    public static string RepositoryRoot => RepositoryRootPath.Value;

    public static string DesktopProjectPath =>
        Path.Combine(RepositoryRoot, "src", "VoxFlow.Desktop", "VoxFlow.Desktop.csproj");

    public static string DesktopProcessName => "VoxFlow.Desktop";

    public static string DesktopAppBundlePath => ResolveDesktopAppBundlePath();

    public static string DesktopExecutablePath =>
        Path.Combine(DesktopAppBundlePath, "Contents", "MacOS", "VoxFlow.Desktop");

    public static string InputFileOne =>
        Path.Combine(RepositoryRoot, "artifacts", "Input", "Test 1.m4a");

    public static string InputFileTwo =>
        Path.Combine(RepositoryRoot, "artifacts", "Input", "Test 2.m4a");

    public static string ModelFile =>
        Path.Combine(RepositoryRoot, "models", "ggml-base.bin");

    public static string UiArtifactsRoot =>
        Path.Combine(RepositoryRoot, "artifacts", "ui-tests");

    public static string DesktopUserConfigPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow",
            "appsettings.json");

    public static string DesktopUiAutomationRootPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow",
            "ui-automation");

    public static string DesktopUiAutomationSessionFilePath =>
        Path.Combine(DesktopUiAutomationRootPath, "active-session.json");

    public static string DesktopUiAutomationRequestsDirectory =>
        Path.Combine(DesktopUiAutomationRootPath, "requests");

    public static string DesktopUiAutomationResponsesDirectory =>
        Path.Combine(DesktopUiAutomationRootPath, "responses");

    private static string FindRepositoryRoot()
    {
        var currentDirectory = new DirectoryInfo(AppContext.BaseDirectory);

        while (currentDirectory is not null)
        {
            if (File.Exists(Path.Combine(currentDirectory.FullName, "VoxFlow.sln")))
            {
                return currentDirectory.FullName;
            }

            currentDirectory = currentDirectory.Parent;
        }

        throw new InvalidOperationException(
            $"Could not locate VoxFlow.sln while searching upward from {AppContext.BaseDirectory}.");
    }

    private static string ResolveDesktopAppBundlePath()
    {
        var configured = Environment.GetEnvironmentVariable("VOXFLOW_DESKTOP_UI_APP_PATH");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return Path.GetFullPath(configured);
        }

        var rid = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.Arm64 => "maccatalyst-arm64",
            Architecture.X64 => "maccatalyst-x64",
            _ => throw new PlatformNotSupportedException(
                $"Unsupported architecture for Desktop UI tests: {RuntimeInformation.ProcessArchitecture}")
        };

        var candidates = new[]
        {
            Path.Combine(RepositoryRoot, "src", "VoxFlow.Desktop", "bin", "Debug", "net9.0-maccatalyst", rid, "VoxFlow.Desktop.app"),
            Path.Combine(RepositoryRoot, "src", "VoxFlow.Desktop", "bin", "Release", "net9.0-maccatalyst", rid, "VoxFlow.Desktop.app")
        };

        var resolved = candidates.FirstOrDefault(Directory.Exists);
        if (resolved is not null)
        {
            return resolved;
        }

        throw new FileNotFoundException(
            "Could not find the built VoxFlow Desktop app bundle. Build the Desktop app first or set VOXFLOW_DESKTOP_UI_APP_PATH.",
            candidates[0]);
    }
}
