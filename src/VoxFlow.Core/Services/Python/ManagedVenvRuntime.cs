using System.Diagnostics;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Default <see cref="IPythonRuntime"/> for Phase 1+: bootstraps a managed
/// virtual environment under an app-support directory, installs pinned
/// pyannote dependencies, and serves the venv interpreter to the sidecar
/// client. Bootstrap is explicit via <see cref="CreateVenvAsync"/>;
/// <see cref="GetStatusAsync"/> never spawns a process.
/// </summary>
public sealed class ManagedVenvRuntime : IPythonRuntime
{
    private readonly IProcessLauncher _launcher;
    private readonly IVenvPaths _paths;

    public ManagedVenvRuntime(IProcessLauncher launcher, IVenvPaths paths)
    {
        ArgumentNullException.ThrowIfNull(launcher);
        ArgumentNullException.ThrowIfNull(paths);
        _launcher = launcher;
        _paths = paths;
    }

    public Task<PythonRuntimeStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        if (File.Exists(_paths.InterpreterPath))
        {
            return Task.FromResult(PythonRuntimeStatus.Ready(_paths.InterpreterPath, version: "managed"));
        }

        return Task.FromResult(PythonRuntimeStatus.NotReadyBootstrapable(
            $"Managed venv not yet created at '{_paths.Root}'. Call CreateVenvAsync to bootstrap.",
            SpeakerLabelingDiagnosticCode.VenvMissing));
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
        psi.ArgumentList.Add(scriptPath);
        foreach (var arg in arguments)
        {
            psi.ArgumentList.Add(arg);
        }
        return psi;
    }

    public async Task CreateVenvAsync(IProgress<VenvBootstrapStage>? progress, CancellationToken cancellationToken)
    {
        try
        {
            progress?.Report(VenvBootstrapStage.CreatingVenv);
            var createVenv = BuildStartInfo("python3", ["-m", "venv", _paths.Root]);
            var venvResult = await _launcher.RunAsync(createVenv, cancellationToken).ConfigureAwait(false);
            if (venvResult.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"python3 -m venv failed with exit code {venvResult.ExitCode}: {venvResult.StdErr}");
            }

            progress?.Report(VenvBootstrapStage.InstallingRequirements);
            var pipInstall = BuildStartInfo(_paths.PipPath, ["install", "-r", _paths.RequirementsFilePath]);
            var pipResult = await _launcher.RunAsync(pipInstall, cancellationToken).ConfigureAwait(false);
            if (pipResult.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"pip install failed with exit code {pipResult.ExitCode}: {pipResult.StdErr}");
            }

            progress?.Report(VenvBootstrapStage.Verifying);
            if (!File.Exists(_paths.InterpreterPath))
            {
                throw new InvalidOperationException(
                    $"venv verification failed: interpreter not found at '{_paths.InterpreterPath}'.");
            }

            progress?.Report(VenvBootstrapStage.Complete);
        }
        catch
        {
            TryDeleteVenv();
            throw;
        }
    }

    private void TryDeleteVenv()
    {
        try
        {
            if (Directory.Exists(_paths.Root))
            {
                Directory.Delete(_paths.Root, recursive: true);
            }
        }
        catch
        {
            // best-effort cleanup; tests assert directory absence, real runs may race.
        }
    }

    private static ProcessStartInfo BuildStartInfo(string fileName, IEnumerable<string> arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in arguments)
        {
            psi.ArgumentList.Add(arg);
        }
        return psi;
    }
}
