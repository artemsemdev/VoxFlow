using VoxFlow.Core.Configuration;

namespace VoxFlow.Core.Interfaces;

public interface IAudioConversionService
{
    Task ConvertToWavAsync(
        string inputPath,
        string outputPath,
        TranscriptionOptions options,
        CancellationToken cancellationToken = default);

    Task<bool> ValidateFfmpegAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default);
}
