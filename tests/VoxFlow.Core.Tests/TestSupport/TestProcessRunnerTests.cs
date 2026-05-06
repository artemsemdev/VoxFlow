using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace VoxFlow.Core.Tests.TestSupport;

public sealed class TestProcessRunnerTests
{
    [Fact]
    public async Task RunRawAsync_CancellationKillsHungChild_WithinTwoHundredMilliseconds()
    {
        // Acceptance criterion from #40: TestProcessRunner must kill the child process
        // tree within 200 ms of cancellation. Spawn `sleep 30` (resolved via PATH so the
        // test works on both macOS and Linux runners) and cancel after the child has
        // started; the await must throw promptly and the kill must have actually fired.
        Skip.If(RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
            "sleep is POSIX-only; the harden targets the Linux core-hosts and macOS desktop CI legs.");

        var startInfo = new ProcessStartInfo("sleep");
        startInfo.ArgumentList.Add("30");

        using var cts = new CancellationTokenSource();
        // Generous outer timeout so the test surfaces the cancellation behaviour, not
        // the timeout codepath (which is exercised separately by RunAppAsync's existing
        // tests).
        var task = TestProcessRunner.RunRawAsync(startInfo, TimeSpan.FromMinutes(5), cts.Token);

        // Give the OS a moment to actually start `sleep` so the kill we issue below
        // really targets a live child.
        await Task.Delay(50);

        var stopwatch = Stopwatch.StartNew();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        stopwatch.Stop();

        Assert.True(
            stopwatch.ElapsedMilliseconds < 200,
            $"Cancel-to-kill propagation took {stopwatch.ElapsedMilliseconds} ms; #40 acceptance bound is 200 ms.");
    }
}
