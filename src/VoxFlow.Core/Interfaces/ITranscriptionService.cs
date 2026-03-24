using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface ITranscriptionService
{
    Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default);
}
