using Xunit;
using Xunit.Abstractions;

namespace VoxFlow.Desktop.Tests;

public sealed class DesktopCliBundleTests
{
    private readonly ITestOutputHelper _output;

    public DesktopCliBundleTests(ITestOutputHelper output)
    {
        _output = output;
    }

    [SkippableFact]
    public void MonoBundleCli_IncludesPyannoteSidecarScript()
    {
        var cliBundleDir = ResolveBuiltCliBundleDir();
        LoudSkip.If(_output, cliBundleDir is null, "Mac Catalyst Desktop app bundle has not been built yet.");

        var expectedScript = Path.Combine(cliBundleDir, "python", "voxflow_diarize.py");
        Assert.True(
            File.Exists(expectedScript),
            $"Pyannote sidecar script is missing from app bundle. Expected at: {expectedScript}. "
                + "CopyBundledCliBridge must copy python/**/* from the CLI output alongside the DLLs.");
    }

    [SkippableFact]
    public void MonoBundleCli_IncludesPythonRequirementsTxt()
    {
        var cliBundleDir = ResolveBuiltCliBundleDir();
        LoudSkip.If(_output, cliBundleDir is null, "Mac Catalyst Desktop app bundle has not been built yet.");

        var expectedRequirements = Path.Combine(cliBundleDir, "python", "python-requirements.txt");
        Assert.True(
            File.Exists(expectedRequirements),
            $"Pinned Python requirements file is missing from app bundle. Expected at: {expectedRequirements}.");
    }

    private static string? ResolveBuiltCliBundleDir()
    {
        var repositoryRoot = TryFindRepositoryRoot();
        if (repositoryRoot is null) return null;

        var desktopBinRoot = Path.Combine(
            repositoryRoot,
            "src", "VoxFlow.Desktop", "bin");
        if (!Directory.Exists(desktopBinRoot)) return null;

        // Prefer the bundle whose CLI bridge was copied most recently. Bundle
        // dir mtimes don't update when internal files change, so we rank by
        // the CLI DLL's mtime (refreshed every CopyBundledCliBridge run).
        var latestBundle = Directory
            .EnumerateDirectories(desktopBinRoot, "VoxFlow.Desktop.app", SearchOption.AllDirectories)
            .Select(dir => Path.Combine(dir, "Contents", "MonoBundle", "cli"))
            .Where(cli => File.Exists(Path.Combine(cli, "VoxFlow.Cli.dll")))
            .OrderByDescending(cli => File.GetLastWriteTimeUtc(Path.Combine(cli, "VoxFlow.Cli.dll")))
            .FirstOrDefault();

        return latestBundle;
    }

    private static string? TryFindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "VoxFlow.sln")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        return null;
    }
}
