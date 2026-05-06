using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;
using Whisper.net;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Diarization;

public sealed class SpeakerEnrichmentServiceTests
{
    private static readonly TranscriptMetadata Metadata =
        new(SchemaVersion: 1, DiarizationModel: "pyannote/test", SidecarVersion: 1);

    private static readonly IReadOnlyList<FilteredSegment> EmptySegments = Array.Empty<FilteredSegment>();

    private static SpeakerLabelingOptions DisabledOptions()
        => SpeakerLabelingOptions.Disabled;

    private static SpeakerLabelingOptions EnabledOptions(int timeoutSeconds = 600)
        => new(
            Enabled: true,
            TimeoutSeconds: timeoutSeconds,
            RuntimeMode: PythonRuntimeMode.ManagedVenv,
            ModelId: "pyannote/test");

    [Fact]
    public async Task EnrichAsync_Disabled_ReturnsEmptyDocument_WithoutTouchingRuntime()
    {
        var runtime = new FakePythonRuntime
        {
            NextStatus = PythonRuntimeStatus.NotReady("should-not-be-queried")
        };
        var sidecar = FakeDiarizationSidecar.ThrowsIfCalled();
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: DisabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Null(result.Document);
        Assert.Empty(result.Warnings);
        Assert.False(result.RuntimeBootstrapped);
        Assert.Equal(0, sidecar.CallCount);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_RuntimeReady_CallsSidecarAndMerges()
    {
        var runtime = new FakePythonRuntime
        {
            NextStatus = PythonRuntimeStatus.Ready("/fake/python", "3.11.0")
        };
        var diarization = new DiarizationResult(
            Version: 1,
            Speakers: new[] { new DiarizationSpeaker("A", 1.0) },
            Segments: new[] { new DiarizationSegment("A", 0.0, 1.0) });
        var sidecar = new FakeDiarizationSidecar((_, _, _) => Task.FromResult(diarization));
        var mergeService = new SpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.Zero,
                TimeSpan.FromSeconds(1),
                "hello",
                Probability: 0.9,
                Words: new[] { new WhisperToken { Start = 0, End = 100, Text = "hello" } })
        };

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: segments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.NotNull(result.Document);
        Assert.Empty(result.Warnings);
        Assert.False(result.RuntimeBootstrapped);
        Assert.Equal(1, sidecar.CallCount);
        Assert.Single(result.Document!.Speakers);
        Assert.Equal("A", result.Document.Speakers[0].Id);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_RuntimeNotReady_VenvNotCreated_BootstrapsAndRecoversSuccessfully()
    {
        var runtime = new FakePythonRuntime();
        runtime.StatusQueue.Enqueue(PythonRuntimeStatus.NotReadyBootstrapable("Managed venv not yet created at '/tmp/venv'."));
        runtime.StatusQueue.Enqueue(PythonRuntimeStatus.Ready("/tmp/venv/bin/python3", "managed"));

        var diarization = new DiarizationResult(
            Version: 1,
            Speakers: new[] { new DiarizationSpeaker("A", 1.0) },
            Segments: new[] { new DiarizationSegment("A", 0.0, 1.0) });
        var sidecar = new FakeDiarizationSidecar((_, _, _) => Task.FromResult(diarization));
        var mergeService = new SpeakerMergeService();
        var bootstrapper = new RecordingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.Zero,
                TimeSpan.FromSeconds(1),
                "hi",
                Probability: 0.9,
                Words: new[] { new WhisperToken { Start = 0, End = 100, Text = "hi" } })
        };

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: segments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.NotNull(result.Document);
        Assert.True(result.RuntimeBootstrapped);
        Assert.Empty(result.Warnings);
        Assert.Equal(1, bootstrapper.CallCount);
        Assert.Equal(1, sidecar.CallCount);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_RuntimeNotReady_NonBootstrapable_ReturnsWarning()
    {
        var runtime = new FakePythonRuntime
        {
            NextStatus = PythonRuntimeStatus.NotReady("python3 not found on PATH")
        };
        var sidecar = FakeDiarizationSidecar.ThrowsIfCalled();
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Null(result.Document);
        Assert.False(result.RuntimeBootstrapped);
        Assert.Single(result.Warnings);
        Assert.StartsWith("speaker-labeling: runtime not ready:", result.Warnings[0]);
        Assert.Contains("python3 not found on PATH", result.Warnings[0]);
        Assert.Equal(0, sidecar.CallCount);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_SidecarReturnsErrorResponse_ReturnsWarning()
    {
        var runtime = new FakePythonRuntime();
        var sidecar = new FakeDiarizationSidecar((_, _, _) =>
            throw new DiarizationSidecarException(
                SidecarFailureReason.ErrorResponseReturned,
                "pyannote: CUDA OOM"));
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Null(result.Document);
        Assert.Single(result.Warnings);
        Assert.Equal("speaker-labeling: error-response-returned: pyannote: CUDA OOM", result.Warnings[0]);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_SidecarCrashes_ReturnsWarning()
    {
        var runtime = new FakePythonRuntime();
        var sidecar = new FakeDiarizationSidecar((_, _, _) =>
            throw new DiarizationSidecarException(
                SidecarFailureReason.ProcessCrashed,
                "exit code -6"));
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Null(result.Document);
        Assert.Single(result.Warnings);
        Assert.Equal("speaker-labeling: process-crashed: exit code -6", result.Warnings[0]);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_SidecarTimesOut_ReturnsWarning_AndDoesNotRethrow()
    {
        var runtime = new FakePythonRuntime();
        var sidecar = new FakeDiarizationSidecar(async (_, _, ct) =>
        {
            // Block until the linked CTS (driven by options.TimeoutSeconds) cancels us.
            // No magic upper bound — if cancellation is broken, the suite-level timeout
            // is the only safety net, which is what we want a regression to surface.
            await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
            return new DiarizationResult(1, Array.Empty<DiarizationSpeaker>(), Array.Empty<DiarizationSegment>());
        });
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: EnabledOptions(timeoutSeconds: 1),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.Null(result.Document);
        Assert.Single(result.Warnings);
        Assert.Equal("speaker-labeling: timed out after 1s", result.Warnings[0]);
    }

    [Fact]
    public async Task EnrichAsync_OuterCancellation_Rethrows()
    {
        var runtime = new FakePythonRuntime();
        using var cts = new CancellationTokenSource();
        var sidecar = new FakeDiarizationSidecar(async (_, _, ct) =>
        {
            cts.Cancel();
            // After cts.Cancel() the linked token is already cancellation-requested,
            // so this throws OperationCanceledException synchronously. Timeout.Infinite
            // documents the intent ("never return on its own — only via ct").
            await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
            return new DiarizationResult(1, Array.Empty<DiarizationSpeaker>(), Array.Empty<DiarizationSegment>());
        });
        var mergeService = new ThrowingSpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await service.EnrichAsync(
                wavPath: "/tmp/audio.wav",
                segments: EmptySegments,
                metadata: Metadata,
                options: EnabledOptions(timeoutSeconds: 600),
                progress: null,
                cancellationToken: cts.Token);
        });
    }

    [Fact]
    public async Task EnrichAsync_Enabled_RuntimeReady_ForwardsProgressAsDiarizingStage()
    {
        var runtime = new FakePythonRuntime();
        var diarization = new DiarizationResult(
            Version: 1,
            Speakers: new[] { new DiarizationSpeaker("A", 1.0) },
            Segments: new[] { new DiarizationSegment("A", 0.0, 1.0) });
        var sidecar = new FakeDiarizationSidecar((_, progress, _) =>
        {
            progress?.Report(new SpeakerLabelingProgress("loading", 0.25));
            progress?.Report(new SpeakerLabelingProgress("diarizing", 0.75));
            return Task.FromResult(diarization);
        });
        var mergeService = new SpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var updates = new List<ProgressUpdate>();
        // Synchronous IProgress<T> — Progress<T> queues to SynchronizationContext/ThreadPool
        // and does not guarantee FIFO ordering between reports, which makes the ordering
        // assertion below flaky. Capturing synchronously on the reporting thread is
        // deterministic and still exercises the same production code path.
        var progress = new SynchronousProgress<ProgressUpdate>(updates.Add);

        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.Zero,
                TimeSpan.FromSeconds(1),
                "hi",
                Probability: 0.9,
                Words: new[] { new WhisperToken { Start = 0, End = 100, Text = "hi" } })
        };

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: segments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: progress,
            cancellationToken: CancellationToken.None);

        Assert.NotNull(result.Document);

        var diarizingUpdates = updates.FindAll(u => u.Stage == ProgressStage.Diarizing);
        // Three updates: one initial "starting" emit before the sidecar runs,
        // plus the two sidecar events. The initial emit covers the Python boot
        // + pyannote import gap that pyannote itself cannot report through.
        Assert.Equal(3, diarizingUpdates.Count);
        Assert.All(diarizingUpdates, u =>
        {
            Assert.InRange(u.PercentComplete, 90.0, 95.0);
        });
        Assert.Equal(90.0, diarizingUpdates[0].PercentComplete);
        // Linear mapping 0..1 → 90..95 should place 0.25 and 0.75 strictly inside the band
        // and strictly above the 90% anchor of the initial "starting" emit.
        Assert.True(diarizingUpdates[1].PercentComplete > diarizingUpdates[0].PercentComplete);
        Assert.True(diarizingUpdates[2].PercentComplete > diarizingUpdates[1].PercentComplete);
    }

    [Fact]
    public async Task EnrichAsync_Enabled_EmitsInitialDiarizingUpdate_BeforeInvokingSidecar()
    {
        // Regression guard: the CLI progress bar must flip to the Diarizing
        // stage label the instant enrichment starts, not only once pyannote
        // itself begins emitting. Otherwise the bar stays stuck on
        // "Transcribing 90%" for 5-30s while the Python sidecar boots and
        // pyannote.audio loads the pipeline from cache.
        var runtime = new FakePythonRuntime();
        var diarization = new DiarizationResult(
            Version: 1,
            Speakers: new[] { new DiarizationSpeaker("A", 1.0) },
            Segments: new[] { new DiarizationSegment("A", 0.0, 1.0) });

        IProgress<SpeakerLabelingProgress>? capturedProgress = null;
        List<ProgressStage>? stagesBeforeSidecarInvocation = null;
        var updates = new List<ProgressUpdate>();
        var progress = new SynchronousProgress<ProgressUpdate>(updates.Add);

        var sidecar = new FakeDiarizationSidecar((_, p, _) =>
        {
            capturedProgress = p;
            stagesBeforeSidecarInvocation = updates.ConvertAll(u => u.Stage);
            return Task.FromResult(diarization);
        });
        var mergeService = new SpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();
        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.Zero,
                TimeSpan.FromSeconds(1),
                "hi",
                Probability: 0.9,
                Words: new[] { new WhisperToken { Start = 0, End = 100, Text = "hi" } })
        };

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: segments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: progress,
            cancellationToken: CancellationToken.None);

        Assert.NotNull(result.Document);
        Assert.NotNull(stagesBeforeSidecarInvocation);
        Assert.Contains(ProgressStage.Diarizing, stagesBeforeSidecarInvocation);
    }

    private sealed class SynchronousProgress<T> : IProgress<T>
    {
        private readonly Action<T> _handler;
        public SynchronousProgress(Action<T> handler) => _handler = handler;
        public void Report(T value) => _handler(value);
    }

    [Fact]
    public async Task EnrichAsync_MergeServiceReturnsEmpty_ProducesWarning()
    {
        var runtime = new FakePythonRuntime();
        var diarization = new DiarizationResult(
            Version: 1,
            Speakers: Array.Empty<DiarizationSpeaker>(),
            Segments: Array.Empty<DiarizationSegment>());
        var sidecar = new FakeDiarizationSidecar((_, _, _) => Task.FromResult(diarization));
        var mergeService = new SpeakerMergeService();
        var bootstrapper = new ThrowingBootstrapper();

        var service = new SpeakerEnrichmentService(runtime, sidecar, mergeService, bootstrapper);

        var result = await service.EnrichAsync(
            wavPath: "/tmp/audio.wav",
            segments: EmptySegments,
            metadata: Metadata,
            options: EnabledOptions(),
            progress: null,
            cancellationToken: CancellationToken.None);

        Assert.NotNull(result.Document);
        Assert.Empty(result.Document!.Speakers);
        Assert.Single(result.Warnings);
        Assert.Equal("speaker-labeling: diarization returned zero speakers", result.Warnings[0]);
    }

    private sealed class RecordingBootstrapper : IManagedVenvBootstrapper
    {
        public int CallCount { get; private set; }
        public Func<IProgress<VenvBootstrapStage>?, CancellationToken, Task>? Handler { get; set; }

        public Task BootstrapAsync(IProgress<VenvBootstrapStage>? progress, CancellationToken cancellationToken)
        {
            CallCount++;
            return Handler?.Invoke(progress, cancellationToken) ?? Task.CompletedTask;
        }
    }

    private sealed class ThrowingSpeakerMergeService : ISpeakerMergeService
    {
        public TranscriptDocument Merge(
            IReadOnlyList<FilteredSegment> segments,
            DiarizationResult diarization,
            TranscriptMetadata metadata)
            => throw new InvalidOperationException("merge service should not be called");
    }

    private sealed class ThrowingBootstrapper : IManagedVenvBootstrapper
    {
        public Task BootstrapAsync(IProgress<VenvBootstrapStage>? progress, CancellationToken cancellationToken)
            => throw new InvalidOperationException("bootstrapper should not be called");
    }
}
