#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Services;

/// <summary>
/// Runs candidate transcriptions and selects the best supported language.
/// </summary>
internal sealed class LanguageSelectionService : ILanguageSelectionService
{
    private readonly ITranscriptionFilter _filter;

    public LanguageSelectionService(ITranscriptionFilter filter)
    {
        _filter = filter;
    }

    /// <summary>
    /// Transcribes the same audio for each configured language and selects the highest-scoring result.
    /// </summary>
    public async Task<LanguageSelectionResult> SelectBestCandidateAsync(
        WhisperFactory factory,
        float[] audioSamples,
        TranscriptionOptions options,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var candidates = new List<CandidateResult>(options.SupportedLanguages.Count);

        // Reuse a single processor across candidate passes to avoid native teardown instability.
        var processor = CreateProcessor(factory, options);

        if (options.SupportedLanguages.Count == 1)
        {
            var language = options.SupportedLanguages[0];
            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing, 0,
                TimeSpan.Zero,
                $"Transcribing {language.DisplayName}",
                language.DisplayName));

            var singleCandidate = await TranscribeCandidateAsync(
                    processor,
                    audioSamples,
                    language,
                    options,
                    candidatePercent => progress?.Report(new ProgressUpdate(
                        ProgressStage.Transcribing,
                        candidatePercent,
                        TimeSpan.Zero,
                        $"Transcribing {language.DisplayName}",
                        language.DisplayName)),
                    cancellationToken)
                .ConfigureAwait(false);

            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing, 100,
                TimeSpan.Zero,
                $"Selected {singleCandidate.Language.DisplayName} with score {singleCandidate.Score:0.000}",
                singleCandidate.Language.DisplayName));

            return ToResult(singleCandidate, null);
        }

        for (var index = 0; index < options.SupportedLanguages.Count; index++)
        {
            var language = options.SupportedLanguages[index];
            var percentComplete = MapCandidateProgressToOverallPercent(index, options.SupportedLanguages.Count, 0);
            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing, percentComplete,
                TimeSpan.Zero,
                $"Transcribing {language.DisplayName}",
                language.DisplayName));

            var candidate = await TranscribeCandidateAsync(
                    processor,
                    audioSamples,
                    language,
                    options,
                    candidatePercent => progress?.Report(new ProgressUpdate(
                        ProgressStage.Transcribing,
                        MapCandidateProgressToOverallPercent(index, options.SupportedLanguages.Count, candidatePercent),
                        TimeSpan.Zero,
                        $"Transcribing {language.DisplayName}",
                        language.DisplayName)),
                    cancellationToken)
                .ConfigureAwait(false);

            candidates.Add(candidate);
        }

        var decision = DecideWinningCandidate(candidates, options);

        progress?.Report(new ProgressUpdate(
            ProgressStage.Transcribing, 100,
            TimeSpan.Zero,
            $"Selected {decision.WinningCandidate.Language.DisplayName} with score {decision.WinningCandidate.Score:0.000}",
            decision.WinningCandidate.Language.DisplayName));

        return ToResult(decision.WinningCandidate, decision.WarningMessage);
    }

    /// <summary>
    /// Creates a Whisper processor configured to reduce hallucinations.
    /// </summary>
    private static WhisperProcessor CreateProcessor(
        WhisperFactory factory,
        TranscriptionOptions options)
    {
        // Whisper requires an initial language when building the processor, even though each candidate pass swaps it immediately.
        var builder = factory.CreateBuilder()
            .WithLanguage(options.SupportedLanguages[0].Code)
            .WithProbabilities()
            .WithNoSpeechThreshold(options.NoSpeechThreshold)
            .WithLogProbThreshold(options.LogProbThreshold)
            .WithEntropyThreshold(options.EntropyThreshold);

        if (options.UseNoContext)
        {
            builder = builder.WithNoContext();
        }

        return builder.Build();
    }

    /// <summary>
    /// Runs a single language-specific transcription pass and filters the resulting segments.
    /// </summary>
    private async Task<CandidateResult> TranscribeCandidateAsync(
        WhisperProcessor processor,
        float[] audioSamples,
        SupportedLanguage language,
        TranscriptionOptions options,
        Action<double>? reportCandidateProgress = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        processor.ChangeLanguage(language.Code);
        var segments = new List<SegmentData>();
        var lastReportedPercent = -1d;

        // The Whisper processor streams segments incrementally, so cancellation can
        // stop a long-running candidate pass without waiting for the full transcript.
        await foreach (var segment in processor.ProcessAsync(audioSamples)
                           .WithCancellation(cancellationToken)
                           .ConfigureAwait(false))
        {
            segments.Add(segment);

            var candidatePercent = CalculateCandidateProgressPercent(
                segment.End,
                audioSamples.Length,
                options.OutputSampleRate);
            if (!ShouldReportCandidateProgress(lastReportedPercent, candidatePercent))
            {
                continue;
            }

            lastReportedPercent = candidatePercent;
            reportCandidateProgress?.Invoke(candidatePercent);
        }

        reportCandidateProgress?.Invoke(100);

        var filteringResult = _filter.FilterSegments(language, segments, options);
        var acceptedSpeechDuration = TimeSpan.FromSeconds(
            filteringResult.Accepted.Sum(segment => (segment.End - segment.Start).TotalSeconds));

        var weightedScore = CalculateWeightedScore(filteringResult.Accepted);

        return new CandidateResult(
            language,
            weightedScore,
            acceptedSpeechDuration,
            filteringResult.Accepted,
            filteringResult.Skipped);
    }

    internal static double MapCandidateProgressToOverallPercent(
        int candidateIndex,
        int candidateCount,
        double candidatePercent)
    {
        var normalizedCount = Math.Max(candidateCount, 1);
        var normalizedIndex = Math.Clamp(candidateIndex, 0, normalizedCount - 1);
        var normalizedPercent = Math.Clamp(candidatePercent, 0d, 100d) / 100d;

        return ((normalizedIndex + normalizedPercent) / normalizedCount) * 100d;
    }

    internal static double CalculateCandidateProgressPercent(
        TimeSpan segmentEnd,
        int totalSampleCount,
        int sampleRate)
    {
        if (totalSampleCount <= 0 || sampleRate <= 0)
        {
            return 0d;
        }

        var totalDurationSeconds = totalSampleCount / (double)sampleRate;
        if (totalDurationSeconds <= 0d)
        {
            return 0d;
        }

        return Math.Clamp((segmentEnd.TotalSeconds / totalDurationSeconds) * 100d, 0d, 100d);
    }

    private static bool ShouldReportCandidateProgress(double lastReportedPercent, double candidatePercent)
        => candidatePercent >= 100d || Math.Floor(candidatePercent) > Math.Floor(lastReportedPercent);

    /// <summary>
    /// Applies the business rules that decide whether a candidate can be accepted.
    /// </summary>
    internal static LanguageSelectionDecision DecideWinningCandidate(
        IReadOnlyList<CandidateResult> candidates,
        TranscriptionOptions options)
    {
        var rankedCandidates = candidates
            .OrderByDescending(candidate => candidate.Score)
            .ThenBy(candidate => candidate.Language.Priority)
            .ToList();

        var winningCandidate = rankedCandidates.FirstOrDefault();
        if (winningCandidate is null || winningCandidate.AcceptedSegments.Count == 0)
        {
            throw new InvalidOperationException(CreateUnsupportedLanguageMessage(options));
        }

        if (winningCandidate.AcceptedSpeechDuration < options.MinAcceptedSpeechDuration)
        {
            throw new InvalidOperationException(CreateUnsupportedLanguageMessage(options));
        }

        if (winningCandidate.Score < options.MinWinningCandidateProbability)
        {
            throw new InvalidOperationException(CreateUnsupportedLanguageMessage(options));
        }

        var runnerUp = rankedCandidates.Skip(1).FirstOrDefault();
        if (runnerUp is null)
        {
            return new LanguageSelectionDecision(winningCandidate, null);
        }

        // Nearly equal scores are treated separately so configuration order can act
        // as a deterministic tie-breaker without also triggering ambiguity warnings.
        var scoreDifference = winningCandidate.Score - runnerUp.Score;
        var isAmbiguous = Math.Abs(scoreDifference) > options.TieBreakerEpsilon &&
                          scoreDifference < options.MinWinningMargin;

        if (!isAmbiguous)
        {
            return new LanguageSelectionDecision(winningCandidate, null);
        }

        if (options.RejectAmbiguousLanguageCandidates)
        {
            throw new InvalidOperationException(CreateUnsupportedLanguageMessage(options, ambiguous: true));
        }

        var warningMessage =
            $"Ambiguous language scores detected. Proceeding with best candidate " +
            $"{winningCandidate.Language.DisplayName} ({winningCandidate.Score:0.000}) " +
            $"over {runnerUp.Language.DisplayName} ({runnerUp.Score:0.000}).";

        return new LanguageSelectionDecision(winningCandidate, warningMessage);
    }

    /// <summary>
    /// Computes a duration-weighted probability score for accepted segments.
    /// </summary>
    private static float CalculateWeightedScore(IReadOnlyList<FilteredSegment> acceptedSegments)
    {
        if (acceptedSegments.Count == 0)
        {
            return 0f;
        }

        double weightedProbabilitySum = 0;
        double durationSum = 0;

        foreach (var segment in acceptedSegments)
        {
            // Clamp very short durations to a small positive value so zero-length
            // timing artifacts do not erase otherwise useful probability data.
            var durationSeconds = Math.Max((segment.End - segment.Start).TotalSeconds, 0.001d);
            weightedProbabilitySum += segment.Probability * durationSeconds;
            durationSum += durationSeconds;
        }

        if (durationSum == 0)
        {
            return 0f;
        }

        return (float)(weightedProbabilitySum / durationSum);
    }

    /// <summary>
    /// Builds the unsupported-language message shown to the caller.
    /// </summary>
    private static string CreateUnsupportedLanguageMessage(TranscriptionOptions options, bool ambiguous = false)
    {
        var prefix = ambiguous ? "Unsupported or ambiguous language detected." : "Unsupported language detected.";
        return $"{prefix} Supported languages are {options.GetSupportedLanguageSummary()}.";
    }

    /// <summary>
    /// Converts an internal candidate result into the public LanguageSelectionResult.
    /// </summary>
    private static LanguageSelectionResult ToResult(CandidateResult candidate, string? warning)
    {
        return new LanguageSelectionResult(
            candidate.Language,
            candidate.Score,
            candidate.AcceptedSpeechDuration,
            candidate.AcceptedSegments,
            candidate.SkippedSegments,
            warning);
    }

    /// <summary>
    /// Represents the scored result of one language candidate transcription.
    /// </summary>
    internal sealed record CandidateResult(
        SupportedLanguage Language,
        float Score,
        TimeSpan AcceptedSpeechDuration,
        IReadOnlyList<FilteredSegment> AcceptedSegments,
        IReadOnlyList<SkippedSegment> SkippedSegments);

    /// <summary>
    /// Represents the outcome of the language-selection decision stage.
    /// </summary>
    internal sealed record LanguageSelectionDecision(
        CandidateResult WinningCandidate,
        string? WarningMessage);
}
