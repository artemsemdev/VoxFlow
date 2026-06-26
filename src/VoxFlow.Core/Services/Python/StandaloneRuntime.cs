using System.Diagnostics;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// <see cref="IPythonRuntime"/> backed by a bundled
/// <c>python-build-standalone</c> tree. The interpreter, stdlib, and
/// site-packages all live under <see cref="IStandaloneRuntimePaths.TreeRoot"/>
/// — no system Python or per-user venv is required.
/// </summary>
public sealed class StandaloneRuntime : IPythonRuntime
{
    private static readonly Version MinimumVersion = new(3, 10);

    private readonly IStandaloneRuntimePaths _paths;
    private readonly IProcessLauncher _launcher;

    public StandaloneRuntime(IStandaloneRuntimePaths paths, IProcessLauncher launcher)
    {
        ArgumentNullException.ThrowIfNull(paths);
        ArgumentNullException.ThrowIfNull(launcher);
        _paths = paths;
        _launcher = launcher;
    }

    public async Task<PythonRuntimeStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        if (!Directory.Exists(_paths.TreeRoot))
        {
            return PythonRuntimeStatus.NotReady(
                $"Standalone Python tree not found at '{_paths.TreeRoot}'.",
                SpeakerLabelingDiagnosticCode.PythonNotFound);
        }

        if (!File.Exists(_paths.InterpreterPath))
        {
            return PythonRuntimeStatus.NotReady(
                $"Standalone Python interpreter not found at '{_paths.InterpreterPath}'.",
                SpeakerLabelingDiagnosticCode.PythonNotFound);
        }

        var versionProbe = new ProcessStartInfo
        {
            FileName = _paths.InterpreterPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        versionProbe.ArgumentList.Add("--version");

        ProcessExecutionResult result;
        try
        {
            result = await _launcher.RunAsync(versionProbe, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return PythonRuntimeStatus.NotReady(
                $"Standalone Python interpreter at '{_paths.InterpreterPath}' could not be executed: {ex.Message}",
                SpeakerLabelingDiagnosticCode.PythonNotFound);
        }

        var combined = string.IsNullOrWhiteSpace(result.StdOut) ? result.StdErr : result.StdOut;
        var versionString = PythonVersionParser.Parse(combined);
        if (versionString is null)
        {
            return PythonRuntimeStatus.NotReady(
                $"Could not parse Python version from '{combined.Trim()}'.",
                SpeakerLabelingDiagnosticCode.PythonVersionUnsupported);
        }

        if (!Version.TryParse(versionString, out var parsed) || parsed < MinimumVersion)
        {
            return PythonRuntimeStatus.NotReady(
                $"Python {versionString} is below the required minimum of {MinimumVersion}.",
                SpeakerLabelingDiagnosticCode.PythonVersionUnsupported);
        }

        return PythonRuntimeStatus.Ready(_paths.InterpreterPath, versionString);
    }

    public ProcessStartInfo CreateStartInfo(string scriptPath, IEnumerable<string> arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptPath);
        ArgumentNullException.ThrowIfNull(arguments);

        var psi = new ProcessStartInfo
        {
            FileName = _paths.InterpreterPath,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        psi.Environment["PYTHONHOME"] = _paths.TreeRoot;
        psi.Environment["PYTHONPATH"] = _paths.SitePackagesPath;
        psi.ArgumentList.Add(scriptPath);
        foreach (var arg in arguments)
        {
            psi.ArgumentList.Add(arg);
        }
        return psi;
    }
}
