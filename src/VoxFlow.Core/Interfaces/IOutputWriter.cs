using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IOutputWriter
{
    Task WriteAsync(
        string outputPath,
        IReadOnlyList<FilteredSegment> segments,
        CancellationToken cancellationToken = default);

    string BuildOutputText(IReadOnlyList<FilteredSegment> segments);
}
