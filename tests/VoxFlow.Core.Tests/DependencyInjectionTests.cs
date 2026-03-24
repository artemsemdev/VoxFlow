using Microsoft.Extensions.DependencyInjection;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using Xunit;

namespace VoxFlow.Core.Tests;

public class DependencyInjectionTests
{
    [Fact]
    public void AddVoxFlowCore_RegistersAllInterfaces()
    {
        var services = new ServiceCollection();
        services.AddVoxFlowCore();
        var provider = services.BuildServiceProvider();

        Assert.NotNull(provider.GetService<IConfigurationService>());
        Assert.NotNull(provider.GetService<IValidationService>());
        Assert.NotNull(provider.GetService<IAudioConversionService>());
        Assert.NotNull(provider.GetService<IModelService>());
        Assert.NotNull(provider.GetService<IWavAudioLoader>());
        Assert.NotNull(provider.GetService<ILanguageSelectionService>());
        Assert.NotNull(provider.GetService<ITranscriptionFilter>());
        Assert.NotNull(provider.GetService<IOutputWriter>());
        Assert.NotNull(provider.GetService<IFileDiscoveryService>());
        Assert.NotNull(provider.GetService<IBatchSummaryWriter>());
        Assert.NotNull(provider.GetService<ITranscriptReader>());
        Assert.NotNull(provider.GetService<ITranscriptionService>());
        Assert.NotNull(provider.GetService<IBatchTranscriptionService>());
    }
}
