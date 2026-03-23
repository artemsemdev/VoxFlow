using System;
using System.IO;
using Xunit;

public sealed class LanguageSelectionDecisionTests
{
    [Fact]
    public void DecideWinningCandidate_AllowsBestScore_WhenAmbiguityRejectionIsDisabled()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            minWinningMargin: 0.05f,
            rejectAmbiguousLanguageCandidates: false);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var german = CreateCandidate("de", "German", 0.934f);
        var ukrainian = CreateCandidate("uk", "Ukrainian", 0.963f);

        var decision = LanguageSelectionService.DecideWinningCandidate([german, ukrainian], options);

        Assert.Equal("uk", decision.WinningCandidate.Language.Code);
        Assert.Contains("Ambiguous language scores detected", decision.WarningMessage, StringComparison.Ordinal);
    }

    [Fact]
    public void DecideWinningCandidate_RejectsAmbiguousScores_WhenConfigured()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            minWinningMargin: 0.05f,
            rejectAmbiguousLanguageCandidates: true);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var german = CreateCandidate("de", "German", 0.934f);
        var ukrainian = CreateCandidate("uk", "Ukrainian", 0.963f);

        Assert.Throws<UnsupportedLanguageException>(
            () => LanguageSelectionService.DecideWinningCandidate([german, ukrainian], options));
    }

    [Fact]
    public void DecideWinningCandidate_SelectsClearWinner_WithNoWarning()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            minWinningMargin: 0.02f,
            rejectAmbiguousLanguageCandidates: false);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var english = CreateCandidate("en", "English", 0.95f);
        var german = CreateCandidate("de", "German", 0.40f);

        var decision = LanguageSelectionService.DecideWinningCandidate([english, german], options);

        Assert.Equal("en", decision.WinningCandidate.Language.Code);
        Assert.Null(decision.WarningMessage);
    }

    [Fact]
    public void DecideWinningCandidate_ThrowsWhenWinnerScoreBelowMinimum()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            minWinningCandidateProbability: 0.80f);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var lowScore = CreateCandidate("en", "English", 0.30f);

        Assert.Throws<UnsupportedLanguageException>(
            () => LanguageSelectionService.DecideWinningCandidate([lowScore], options));
    }

    [Fact]
    public void DecideWinningCandidate_ThrowsWhenNoCandidatesHaveSegments()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var emptyCandidate = new CandidateTranscriptionResult(
            new SupportedLanguage("en", "English", 0),
            0.0f,
            TimeSpan.Zero,
            Array.Empty<FilteredSegment>(),
            Array.Empty<SkippedSegment>());

        Assert.Throws<UnsupportedLanguageException>(
            () => LanguageSelectionService.DecideWinningCandidate([emptyCandidate], options));
    }

    [Fact]
    public void DecideWinningCandidate_UsesTieBreakPriority_WhenScoresAreNearlyEqual()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            tieBreakerEpsilon: 0.01f,
            minWinningMargin: 0.02f,
            rejectAmbiguousLanguageCandidates: false);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        // Same score: tie-break by Priority (lower = preferred).
        var english = CreateCandidateWithPriority("en", "English", 0.90f, 0);
        var german = CreateCandidateWithPriority("de", "German", 0.90f, 1);

        var decision = LanguageSelectionService.DecideWinningCandidate([german, english], options);

        Assert.Equal("en", decision.WinningCandidate.Language.Code);
    }

    private static CandidateTranscriptionResult CreateCandidate(string code, string displayName, float score)
    {
        return CreateCandidateWithPriority(code, displayName, score, 0);
    }

    private static CandidateTranscriptionResult CreateCandidateWithPriority(
        string code, string displayName, float score, int priority)
    {
        var language = new SupportedLanguage(code, displayName, priority);
        var acceptedSegment = new FilteredSegment(
            "sample",
            TimeSpan.Zero,
            TimeSpan.FromSeconds(5),
            score,
            language);

        return new CandidateTranscriptionResult(
            language,
            score,
            TimeSpan.FromSeconds(5),
            [acceptedSegment],
            Array.Empty<SkippedSegment>());
    }
}
