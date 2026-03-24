using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IBatchTranscriptionService
{
    Task<BatchTranscribeResult> TranscribeBatchAsync(
        BatchTranscribeRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default);
}
