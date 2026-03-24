using Microsoft.Extensions.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Services;

namespace VoxFlow.Core.DependencyInjection;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddVoxFlowCore(this IServiceCollection services)
    {
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
        services.AddSingleton<ITranscriptionService, TranscriptionService>();
        services.AddSingleton<IBatchTranscriptionService, BatchTranscriptionService>();
        return services;
    }
}
