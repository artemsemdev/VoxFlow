using VoxFlow.Core.Configuration;

namespace VoxFlow.Core.Interfaces;

public interface IWavAudioLoader
{
    Task<float[]> LoadSamplesAsync(
        string wavPath,
        TranscriptionOptions options,
        CancellationToken cancellationToken = default);
}
