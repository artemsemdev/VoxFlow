using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Interfaces;

public interface IModelService
{
    Task<WhisperFactory> GetOrCreateFactoryAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default);

    ModelInfo InspectModel(TranscriptionOptions options);
}
