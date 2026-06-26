using System.Diagnostics;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Resolves the <c>python3</c> interpreter from <c>PATH</c>. Dev/CI escape
/// hatch for local speaker labeling — production builds use
/// <c>ManagedVenvRuntime</c>. Verifies the interpreter exists and meets the
/// 3.10 minimum by shelling out to <c>python3 --version</c>.
/// </summary>
public sealed class SystemPythonRuntime : IPythonRuntime
{
    private const string InterpreterFileName = "python3";
    private static readonly Version MinimumVersion = new(3, 10);

    private readonly IProcessLauncher _launcher;

    public SystemPythonRuntime(IProcessLauncher launcher)
    {
        ArgumentNullException.ThrowIfNull(launcher);
        _launcher = launcher;
    }

    public async Task<PythonRuntimeStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = InterpreterFileName,
            RedirectStandardInput = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("--version");

        ProcessExecutionResult result;
        try
        {
            result = await _launcher.RunAsync(startInfo, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return PythonRuntimeStatus.NotReady(
                $"python3 not found in PATH: {ex.Message}",
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

        return PythonRuntimeStatus.Ready(InterpreterFileName, versionString);
    }

    public ProcessStartInfo CreateStartInfo(string scriptPath, IEnumerable<string> arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptPath);
        ArgumentNullException.ThrowIfNull(arguments);

        var startInfo = new ProcessStartInfo
        {
            FileName = InterpreterFileName,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var arg in arguments)
        {
            startInfo.ArgumentList.Add(arg);
        }

        return startInfo;
    }
}
