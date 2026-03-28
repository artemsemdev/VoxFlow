using VoxFlow.Core.Services;
using Xunit;

namespace VoxFlow.Core.Tests;

public sealed class TranscriptionProgressTests
{
    [Theory]
    [InlineData(0, 30)]
    [InlineData(50, 60)]
    [InlineData(100, 90)]
    public void MapLanguageSelectionPercentToPipelinePercent_UsesTranscriptionWindow(
        double selectionPercent,
        double expectedPipelinePercent)
    {
        var pipelinePercent = TranscriptionService.MapLanguageSelectionPercentToPipelinePercent(selectionPercent);

        Assert.Equal(expectedPipelinePercent, pipelinePercent);
    }

    [Theory]
    [InlineData(0, 1, 0, 0)]
    [InlineData(0, 1, 50, 50)]
    [InlineData(0, 1, 100, 100)]
    [InlineData(1, 2, 50, 75)]
    public void MapCandidateProgressToOverallPercent_ScalesAcrossCandidates(
        int candidateIndex,
        int candidateCount,
        double candidatePercent,
        double expectedOverallPercent)
    {
        var overallPercent = LanguageSelectionService.MapCandidateProgressToOverallPercent(
            candidateIndex,
            candidateCount,
            candidatePercent);

        Assert.Equal(expectedOverallPercent, overallPercent);
    }

    [Fact]
    public void CalculateCandidateProgressPercent_UsesSegmentEndRelativeToAudioDuration()
    {
        var candidatePercent = LanguageSelectionService.CalculateCandidateProgressPercent(
            TimeSpan.FromSeconds(2.5),
            totalSampleCount: 160_000,
            sampleRate: 16_000);

        Assert.Equal(25d, candidatePercent);
    }
}
