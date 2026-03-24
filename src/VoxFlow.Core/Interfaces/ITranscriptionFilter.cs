using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Interfaces;

public interface ITranscriptionFilter
{
    CandidateFilteringResult FilterSegments(
        SupportedLanguage language,
        IReadOnlyList<SegmentData> segments,
        TranscriptionOptions options);
}
