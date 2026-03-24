using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IBatchSummaryWriter
{
    Task WriteAsync(
        string summaryPath,
        IReadOnlyList<FileProcessingResult> results,
        CancellationToken cancellationToken = default);
}
