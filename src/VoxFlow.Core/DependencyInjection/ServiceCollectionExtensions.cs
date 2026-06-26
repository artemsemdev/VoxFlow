using System.Reflection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Services;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.DependencyInjection;

/// <summary>
/// Registers the shared VoxFlow core services used by CLI, Desktop, and MCP hosts.
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Adds the core transcription pipeline services to the supplied service collection.
    ///
    /// Logging contract (#46 Phase 1): if the host has called
    /// <c>services.AddLogging(...)</c> before this method, the host's
    /// <see cref="ILoggerFactory"/> is reused and Core services receive its
    /// <see cref="ILogger{T}"/> instances. If logging is not registered,
    /// the open-generic <see cref="ILogger{T}"/> resolves to
    /// <see cref="NullLogger{T}"/> — Core services keep working but their
    /// log lines go nowhere.
    /// </summary>
    public static IServiceCollection AddVoxFlowCore(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        // TryAdd, not Add: if the host has registered AddLogging() with real
        // providers, that registration wins. This line only fires when nobody
        // wired logging — the NullLogger fallback keeps tests and minimal hosts
        // working without forcing them to set up logging up front.
        services.TryAdd(ServiceDescriptor.Singleton(typeof(ILogger<>), typeof(NullLogger<>)));

        services.AddSingleton<IConfigurationService, ConfigurationService>();
        services.AddSingleton<IValidationService, ValidationService>();
        services.AddSingleton<IAudioConversionService, AudioConversionService>();
        services.AddSingleton<IModelService, ModelService>();
        services.AddSingleton<IWavAudioLoader, WavAudioLoader>();
        services.AddSingleton<ILanguageSelectionService, LanguageSelectionService>();
        services.AddSingleton<ITranscriptionFilter, TranscriptionFilter>();
        services.AddSingleton<IOutputWriter, OutputWriter>();
        services.AddSingleton<IFileDiscoveryService, FileDiscoveryService>();
        services.AddSingleton<IBatchSummaryWriter, BatchSummaryWriter>();
        services.AddSingleton<ITranscriptReader, TranscriptReader>();
        services.AddSingleton<ISpeakerMergeService, SpeakerMergeService>();
        services.AddSingleton<IProcessLauncher, DefaultProcessLauncher>();
        services.AddSingleton<IVenvPaths, DefaultVenvPaths>();
        services.AddSingleton<IStandaloneRuntimePaths, DefaultStandaloneRuntimePaths>();
        services.AddSingleton<ISpeakerEnrichmentService>(sp =>
            new CompositionSpeakerEnrichmentService(
                sp.GetRequiredService<IProcessLauncher>(),
                sp.GetRequiredService<IVenvPaths>(),
                sp.GetRequiredService<IStandaloneRuntimePaths>(),
                sp.GetRequiredService<ISpeakerMergeService>(),
                ResolveSidecarScriptPath(),
                sp.GetService<ILoggerFactory>()));
        services.AddSingleton<ISpeakerLabelingPreflight>(sp =>
            new CompositionSpeakerLabelingPreflight(
                sp.GetRequiredService<IProcessLauncher>(),
                sp.GetRequiredService<IVenvPaths>(),
                CompositionSpeakerLabelingPreflight.ResolveDefaultHubCacheRoot()));
        services.AddSingleton<IVoxflowTranscriptArtifactWriter, VoxflowTranscriptArtifactWriter>();
        services.AddSingleton<ITranscriptionService, TranscriptionService>();
        services.AddSingleton<IBatchTranscriptionService, BatchTranscriptionService>();
        services.AddSingleton<IRuntimeStampStore>(_ => new RuntimeStampStore(DefaultRuntimeStampPath.FilePath));
        services.AddSingleton<ISpeakerLabelingDoctor>(sp =>
            new SpeakerLabelingDoctor(
                sp.GetRequiredService<IConfigurationService>(),
                sp.GetRequiredService<ISpeakerLabelingPreflight>(),
                sp.GetRequiredService<IRuntimeStampStore>(),
                sp.GetRequiredService<IVenvPaths>().RequirementsFilePath,
                ResolveSidecarScriptPath()));
        return services;
    }

    /// <summary>
    /// Locates <c>voxflow_diarize.py</c> next to the currently executing
    /// assembly. Tests link the script into <c>python/voxflow_diarize.py</c>
    /// under the test output dir; production packaging uses the same layout.
    /// </summary>
    private static string ResolveSidecarScriptPath()
    {
        var assemblyDir = Path.GetDirectoryName(typeof(ServiceCollectionExtensions).Assembly.Location)
            ?? AppContext.BaseDirectory;
        var candidate = Path.Combine(assemblyDir, "python", "voxflow_diarize.py");
        return candidate;
    }
}
