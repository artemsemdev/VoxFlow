using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Interfaces;

public interface ILanguageSelectionService
{
    Task<LanguageSelectionResult> SelectBestCandidateAsync(
        WhisperFactory factory,
        float[] audioSamples,
        TranscriptionOptions options,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default);
}
