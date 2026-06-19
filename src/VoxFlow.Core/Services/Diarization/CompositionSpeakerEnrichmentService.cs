using Microsoft.Extensions.Logging;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <summary>
/// <see cref="ISpeakerEnrichmentService"/> implementation that composes the
/// concrete <see cref="IPythonRuntime"/>, <see cref="IDiarizationSidecar"/>,
/// and <see cref="IManagedVenvBootstrapper"/> tree on each invocation based
/// on the <see cref="SpeakerLabelingOptions.RuntimeMode"/>, then delegates
/// to an inner <see cref="SpeakerEnrichmentService"/>.
/// </summary>
/// <remarks>
/// Rebuilding per call keeps <c>ISpeakerEnrichmentService</c> a pure DI
/// singleton while still letting callers flip the runtime mode in
/// <c>appsettings.json</c> without re-bootstrapping the container. The
/// inner-factory constructor hook exists so tests can substitute a stub
/// and avoid touching the filesystem.
/// </remarks>
public sealed class CompositionSpeakerEnrichmentService : ISpeakerEnrichmentService
{
    private readonly Func<SpeakerLabelingOptions, ISpeakerEnrichmentService> _innerFactory;

    /// <summary>
    /// Production constructor used by DI. Binds launcher/paths/merge-service
    /// and resolves the sidecar script next to the current assembly.
    /// </summary>
    public CompositionSpeakerEnrichmentService(
        IProcessLauncher launcher,
        IVenvPaths venvPaths,
        IStandaloneRuntimePaths standalonePaths,
        ISpeakerMergeService mergeService,
        string sidecarScriptPath,
        ILoggerFactory? loggerFactory = null)
    {
        ArgumentNullException.ThrowIfNull(launcher);
        ArgumentNullException.ThrowIfNull(venvPaths);
        ArgumentNullException.ThrowIfNull(standalonePaths);
        ArgumentNullException.ThrowIfNull(mergeService);
        ArgumentException.ThrowIfNullOrWhiteSpace(sidecarScriptPath);

        _innerFactory = options =>
        {
            var runtime = BuildRuntime(options.RuntimeMode, launcher, venvPaths, standalonePaths);
            var bootstrapper = BuildBootstrapper(options.RuntimeMode, runtime);
            var sidecar = new PyannoteSidecarClient(
                runtime,
                launcher,
                sidecarScriptPath,
                TimeSpan.FromSeconds(options.TimeoutSeconds),
                loggerFactory?.CreateLogger<PyannoteSidecarClient>());
            return new SpeakerEnrichmentService(
                runtime,
                sidecar,
                mergeService,
                bootstrapper,
                loggerFactory?.CreateLogger<SpeakerEnrichmentService>());
        };
    }

    /// <summary>
    /// Constructor that takes an explicit inner-factory. Primarily used by
    /// tests to substitute the enrichment tree without touching the
    /// filesystem; also usable by hosts that want full control over runtime
    /// composition.
    /// </summary>
    public CompositionSpeakerEnrichmentService(
        Func<SpeakerLabelingOptions, ISpeakerEnrichmentService> innerFactory)
    {
        ArgumentNullException.ThrowIfNull(innerFactory);
        _innerFactory = innerFactory;
    }

    public Task<SpeakerEnrichmentResult> EnrichAsync(
        string wavPath,
        IReadOnlyList<FilteredSegment> segments,
        TranscriptMetadata metadata,
        SpeakerLabelingOptions options,
        IProgress<ProgressUpdate>? progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (!options.Enabled)
        {
            return Task.FromResult(SpeakerEnrichmentResult.Empty);
        }

        var inner = _innerFactory(options);
        return inner.EnrichAsync(wavPath, segments, metadata, options, progress, cancellationToken);
    }

    internal static IPythonRuntime BuildRuntime(
        PythonRuntimeMode mode,
        IProcessLauncher launcher,
        IVenvPaths venvPaths,
        IStandaloneRuntimePaths standalonePaths)
        => mode switch
        {
            PythonRuntimeMode.ManagedVenv => new ManagedVenvRuntime(launcher, venvPaths),
            PythonRuntimeMode.SystemPython => new SystemPythonRuntime(launcher),
            PythonRuntimeMode.Standalone => new StandaloneRuntime(standalonePaths, launcher),
            _ => throw new NotSupportedException($"Unsupported runtime mode: {mode}")
        };

    private static IManagedVenvBootstrapper BuildBootstrapper(
        PythonRuntimeMode mode,
        IPythonRuntime runtime)
        => mode switch
        {
            PythonRuntimeMode.ManagedVenv when runtime is ManagedVenvRuntime managed
                => new ManagedVenvBootstrapper(managed),
            _ => new NoOpManagedVenvBootstrapper()
        };

    private sealed class NoOpManagedVenvBootstrapper : IManagedVenvBootstrapper
    {
        public Task BootstrapAsync(IProgress<VenvBootstrapStage>? progress, CancellationToken cancellationToken)
            => Task.CompletedTask;
    }
}
