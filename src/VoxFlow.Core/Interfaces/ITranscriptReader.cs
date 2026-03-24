using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface ITranscriptReader
{
    Task<TranscriptReadResult> ReadAsync(
        string path,
        int? maxCharacters = null,
        CancellationToken cancellationToken = default);
}
