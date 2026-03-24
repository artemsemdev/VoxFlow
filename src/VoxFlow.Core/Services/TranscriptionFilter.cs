#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using Whisper.net;

namespace VoxFlow.Core.Services;

/// <summary>
/// Filters raw Whisper segments to keep only useful speech content.
/// </summary>
internal sealed class TranscriptionFilter : ITranscriptionFilter
{
    /// <summary>
    /// Filters segments for one language candidate and records skipped-segment reasons.
    /// </summary>
    public CandidateFilteringResult FilterSegments(
        SupportedLanguage language,
        IReadOnlyList<SegmentData> segments,
        TranscriptionOptions options)
    {
        var acceptedSegments = new List<FilteredSegment>(segments.Count);
        var skippedSegments = new List<SkippedSegment>();

        foreach (var segment in segments)
        {
            var normalizedText = NormalizeWhitespace(segment.Text);
            var skipReason = GetSkipReason(segment, normalizedText, options);

            if (skipReason is not null)
            {
                skippedSegments.Add(new SkippedSegment(
                    segment.Start,
                    segment.End,
                    normalizedText,
                    segment.Probability,
                    skipReason.Value));
                continue;
            }

            acceptedSegments.Add(new FilteredSegment(
                segment.Start,
                segment.End,
                normalizedText,
                segment.Probability));
        }

        var deduplicatedSegments = ApplyDuplicateLoopFiltering(acceptedSegments, skippedSegments, options);

        return new CandidateFilteringResult(deduplicatedSegments, skippedSegments);
    }

    /// <summary>
    /// Determines why a segment should be skipped, or returns null when it is acceptable.
    /// </summary>
    private static SegmentSkipReason? GetSkipReason(
        SegmentData segment,
        string normalizedText,
        TranscriptionOptions options)
    {
        if (string.IsNullOrWhiteSpace(normalizedText))
        {
            return SegmentSkipReason.EmptyText;
        }

        if (IsNoiseMarker(normalizedText, options.NonSpeechMarkers))
        {
            return SegmentSkipReason.NoiseMarker;
        }

        if (options.SuppressBracketedNonSpeechSegments && IsBracketedNonSpeechPlaceholder(normalizedText))
        {
            return SegmentSkipReason.BracketedPlaceholder;
        }

        if (segment.Probability < options.MinSegmentProbability)
        {
            return SegmentSkipReason.LowProbability;
        }

        var duration = segment.End - segment.Start;
        if (duration > options.LongLowInformationSegmentThreshold &&
            normalizedText.Length < options.MinTextLengthForLongSegment)
        {
            return SegmentSkipReason.LowInformationLong;
        }

        if (LooksLikeSuspiciousNonSpeech(normalizedText))
        {
            return SegmentSkipReason.SuspiciousNonSpeech;
        }

        return null;
    }

    /// <summary>
    /// Collapses repeated whitespace to keep output and filtering consistent.
    /// </summary>
    internal static string NormalizeWhitespace(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return string.Empty;
        }

        var trimmed = text.AsSpan().Trim();
        var builder = new StringBuilder(trimmed.Length);
        var previousWasWhitespace = false;

        foreach (var character in trimmed)
        {
            if (char.IsWhiteSpace(character))
            {
                if (!previousWasWhitespace)
                {
                    builder.Append(' ');
                    previousWasWhitespace = true;
                }

                continue;
            }

            builder.Append(character);
            previousWasWhitespace = false;
        }

        return builder.ToString();
    }

    /// <summary>
    /// Detects configured noise markers, including bracketed placeholders such as "[music]".
    /// </summary>
    private static bool IsNoiseMarker(string text, IReadOnlySet<string> nonSpeechMarkers)
    {
        var canonical = CanonicalizeText(text);

        if (nonSpeechMarkers.Contains(canonical))
        {
            return true;
        }

        if (text.Length >= 3 &&
            ((text[0] == '[' && text[^1] == ']') ||
             (text[0] == '(' && text[^1] == ')')))
        {
            var innerText = CanonicalizeText(text.AsSpan(1, text.Length - 2));
            return nonSpeechMarkers.Contains(innerText);
        }

        return false;
    }

    /// <summary>
    /// Detects bracketed stage directions such as "[door opening]" that should not reach the final transcript.
    /// </summary>
    internal static bool IsBracketedNonSpeechPlaceholder(string text)
    {
        if (text.Length < 3)
        {
            return false;
        }

        var isBracketed =
            (text[0] == '[' && text[^1] == ']') ||
            (text[0] == '(' && text[^1] == ')');

        if (!isBracketed)
        {
            return false;
        }

        var innerText = text.AsSpan(1, text.Length - 2).Trim();
        if (innerText.Length == 0 || innerText.IndexOfAny(".?!:;".AsSpan()) >= 0)
        {
            return false;
        }

        var words = innerText.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length == 0 || words.Length > 6)
        {
            return false;
        }

        return words.All(word => word.All(character => char.IsLetter(character) || character is '\'' or '-'));
    }

    /// <summary>
    /// Drops repeated short phrases that often appear when the model hallucinates through silence.
    /// </summary>
    private static IReadOnlyList<FilteredSegment> ApplyDuplicateLoopFiltering(
        IReadOnlyList<FilteredSegment> acceptedSegments,
        ICollection<SkippedSegment> skippedSegments,
        TranscriptionOptions options)
    {
        var filteredSegments = new List<FilteredSegment>(acceptedSegments.Count);
        string? previousCanonicalText = null;
        var consecutiveDuplicateCount = 0;

        foreach (var segment in acceptedSegments)
        {
            var canonicalText = CanonicalizeText(segment.Text);
            var qualifiesForDuplicateFiltering =
                canonicalText.Length > 0 &&
                canonicalText.Length <= options.MaxDuplicateSegmentTextLength;

            if (qualifiesForDuplicateFiltering &&
                string.Equals(previousCanonicalText, canonicalText, StringComparison.Ordinal))
            {
                consecutiveDuplicateCount++;
            }
            else
            {
                consecutiveDuplicateCount = 1;
                previousCanonicalText = qualifiesForDuplicateFiltering ? canonicalText : null;
            }

            if (qualifiesForDuplicateFiltering &&
                consecutiveDuplicateCount > options.MaxConsecutiveDuplicateSegments)
            {
                skippedSegments.Add(new SkippedSegment(
                    segment.Start,
                    segment.End,
                    segment.Text,
                    segment.Probability,
                    SegmentSkipReason.RepetitiveLoop));
                continue;
            }

            filteredSegments.Add(segment);
        }

        return filteredSegments;
    }

    /// <summary>
    /// Flags segments that contain no letters or digits and are likely not speech.
    /// Short-circuits on the first letter or digit found for better performance.
    /// </summary>
    private static bool LooksLikeSuspiciousNonSpeech(string text)
    {
        foreach (var character in text)
        {
            if (char.IsLetterOrDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Normalizes text into a lowercase alphanumeric form used for marker matching.
    /// </summary>
    private static string CanonicalizeText(string text)
    {
        return CanonicalizeText(text.AsSpan());
    }

    /// <summary>
    /// Normalizes a text span into a lowercase alphanumeric form used for marker matching.
    /// </summary>
    private static string CanonicalizeText(ReadOnlySpan<char> text)
    {
        var builder = new StringBuilder(text.Length);

        foreach (var character in text)
        {
            if (char.IsLetterOrDigit(character))
            {
                builder.Append(char.ToLowerInvariant(character));
            }
        }

        return builder.ToString();
    }
}
