using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Python;

public sealed class ManagedVenvRuntimeTests
{
    [Fact]
    public async Task GetStatus_VenvNotYetCreated_ReturnsNotReady_WithCreateHint()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        var runtime = new ManagedVenvRuntime(launcher, paths);

        var status = await runtime.GetStatusAsync(CancellationToken.None);

        Assert.False(status.IsReady);
        Assert.NotNull(status.Error);
        Assert.Contains("CreateVenv", status.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(SpeakerLabelingDiagnosticCode.VenvMissing, status.DiagnosticCode);
        Assert.Empty(launcher.Invocations);
    }

    [Fact]
    public async Task CreateVenv_FreshDirectory_CallsPythonVenvCreate()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        launcher.SetResponse("python3", exitCode: 0, stdOut: string.Empty);
        launcher.SetResponse(paths.PipPath, exitCode: 0, stdOut: string.Empty);
        // Materialize the venv "after" python -m venv runs; FakeProcessLauncher
        // doesn't care about ordering so create it up front for pip path lookup.
        paths.MaterializeVenv();

        var runtime = new ManagedVenvRuntime(launcher, paths);

        await runtime.CreateVenvAsync(progress: null, CancellationToken.None);

        Assert.NotEmpty(launcher.Invocations);
        var first = launcher.Invocations[0];
        Assert.Equal("python3", first.FileName);
        var args = first.ArgumentList.ToList();
        Assert.Contains("-m", args);
        Assert.Contains("venv", args);
        Assert.Contains(paths.Root, args);
    }

    [Fact]
    public async Task CreateVenv_InstallsRequirements_AfterVenvCreated()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        launcher.SetResponse("python3", exitCode: 0, stdOut: string.Empty);
        launcher.SetResponse(paths.PipPath, exitCode: 0, stdOut: string.Empty);
        paths.MaterializeVenv();

        var runtime = new ManagedVenvRuntime(launcher, paths);
        await runtime.CreateVenvAsync(progress: null, CancellationToken.None);

        Assert.True(launcher.Invocations.Count >= 2);
        var second = launcher.Invocations[1];
        Assert.Equal(paths.PipPath, second.FileName);
        var args = second.ArgumentList.ToList();
        Assert.Contains("install", args);
        Assert.Contains("-r", args);
        Assert.Contains(paths.RequirementsFilePath, args);
    }

    [Fact]
    public async Task CreateVenv_FailureDuringPipInstall_PropagatesError_AndCleansUp()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        launcher.SetResponse("python3", exitCode: 0, stdOut: string.Empty);
        // Simulate python -m venv creating the venv dir and bin/pip so the
        // ManagedVenvRuntime's cleanup has real files to remove.
        paths.MaterializeVenv();
        launcher.SetResponse(paths.PipPath, exitCode: 1, stdOut: string.Empty, stdErr: "could not resolve torch==x.y.z");

        var runtime = new ManagedVenvRuntime(launcher, paths);

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => runtime.CreateVenvAsync(progress: null, CancellationToken.None));

        Assert.Contains("pip install", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(Directory.Exists(paths.Root), "Partial venv should be cleaned up on failure.");
    }

    [Fact]
    public async Task GetStatus_VenvExists_ReturnsReady_WithInterpreterPath()
    {
        using var paths = new FakeVenvPaths();
        paths.MaterializeVenv();
        var launcher = new FakeProcessLauncher();
        var runtime = new ManagedVenvRuntime(launcher, paths);

        var status = await runtime.GetStatusAsync(CancellationToken.None);

        Assert.True(status.IsReady);
        Assert.Equal(paths.InterpreterPath, status.InterpreterPath);
        Assert.Empty(launcher.Invocations);
    }

    [Fact]
    public void CreateStartInfo_UsesVenvInterpreter()
    {
        using var paths = new FakeVenvPaths();
        var runtime = new ManagedVenvRuntime(new FakeProcessLauncher(), paths);

        var psi = runtime.CreateStartInfo("/tmp/voxflow_diarize.py", new[] { "--input", "a.wav" });

        Assert.Equal(paths.InterpreterPath, psi.FileName);
        Assert.NotEqual("python3", psi.FileName);
        Assert.True(psi.RedirectStandardInput);
        Assert.True(psi.RedirectStandardOutput);
        Assert.True(psi.RedirectStandardError);
        Assert.False(psi.UseShellExecute);
        Assert.Contains("/tmp/voxflow_diarize.py", psi.ArgumentList.ToList());
        Assert.Contains("--input", psi.ArgumentList.ToList());
        Assert.Contains("a.wav", psi.ArgumentList.ToList());
    }

    [Fact]
    public async Task CreateVenv_WithProgressReporter_ReportsEachStage()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        launcher.SetResponse("python3", exitCode: 0, stdOut: string.Empty);
        launcher.SetResponse(paths.PipPath, exitCode: 0, stdOut: string.Empty);
        paths.MaterializeVenv();

        var progress = new SynchronousProgress<VenvBootstrapStage>();

        var runtime = new ManagedVenvRuntime(launcher, paths);
        await runtime.CreateVenvAsync(progress, CancellationToken.None);

        Assert.Equal(
            new[]
            {
                VenvBootstrapStage.CreatingVenv,
                VenvBootstrapStage.InstallingRequirements,
                VenvBootstrapStage.Verifying,
                VenvBootstrapStage.Complete
            },
            progress.Reports);
    }

    [Fact]
    public async Task CreateVenv_Cancelled_StopsCleanly()
    {
        using var paths = new FakeVenvPaths();
        var launcher = new FakeProcessLauncher();
        launcher.SetResponse("python3", exitCode: 0, stdOut: string.Empty);
        // Materialize the venv so pip has a target, then make pip hang until cancellation.
        paths.MaterializeVenv();
        launcher.SetNeverReturns(paths.PipPath);

        var runtime = new ManagedVenvRuntime(launcher, paths);
        using var cts = new CancellationTokenSource();

        var task = runtime.CreateVenvAsync(progress: null, cts.Token);
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);

        var status = await runtime.GetStatusAsync(CancellationToken.None);
        Assert.False(status.IsReady);
        Assert.False(Directory.Exists(paths.Root), "Cancellation should tear down the partial venv.");
    }

    private sealed class SynchronousProgress<T> : IProgress<T>
    {
        public List<T> Reports { get; } = new();
        public void Report(T value) => Reports.Add(value);
    }
}
