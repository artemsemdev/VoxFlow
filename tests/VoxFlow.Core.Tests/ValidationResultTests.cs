using System.Linq;
using VoxFlow.Core.Models;
using Xunit;

namespace VoxFlow.Core.Tests;

/// <summary>
/// Tests for <see cref="ValidationResult"/> and <see cref="ValidationCheck"/> models,
/// adapted from the original StartupValidationReportTests.
/// </summary>
public sealed class ValidationResultTests
{
    [Fact]
    public void Outcome_IsPassedWithWarnings_WhenThereAreWarningsAndNoFailures()
    {
        var checks = new[]
        {
            new ValidationCheck("Settings", ValidationCheckStatus.Passed, "OK"),
            new ValidationCheck("Model", ValidationCheckStatus.Warning, "Will be downloaded")
        };

        var result = CreateResult(checks);

        Assert.True(result.CanStart);
        Assert.True(result.HasWarnings);
        Assert.Equal("PASSED WITH WARNINGS", result.Outcome);
    }

    [Fact]
    public void Outcome_IsFailed_WhenAnyCheckFails()
    {
        var checks = new[]
        {
            new ValidationCheck("Settings", ValidationCheckStatus.Passed, "OK"),
            new ValidationCheck("Input file", ValidationCheckStatus.Failed, "Missing")
        };

        var result = CreateResult(checks);

        Assert.False(result.CanStart);
        Assert.Equal("FAILED", result.Outcome);
    }

    [Fact]
    public void Outcome_IsPassed_WhenAllChecksPassed()
    {
        var checks = new[]
        {
            new ValidationCheck("Settings", ValidationCheckStatus.Passed, "OK"),
            new ValidationCheck("Input file", ValidationCheckStatus.Passed, "Found"),
            new ValidationCheck("ffmpeg", ValidationCheckStatus.Passed, "Available")
        };

        var result = CreateResult(checks);

        Assert.True(result.CanStart);
        Assert.False(result.HasWarnings);
        Assert.Equal("PASSED", result.Outcome);
    }

    [Fact]
    public void Outcome_IsPassed_WhenOnlySkippedAndPassed()
    {
        var checks = new[]
        {
            new ValidationCheck("Settings", ValidationCheckStatus.Passed, "OK"),
            new ValidationCheck("Whisper runtime", ValidationCheckStatus.Skipped, "Disabled by configuration.")
        };

        var result = CreateResult(checks);

        Assert.True(result.CanStart);
        Assert.False(result.HasWarnings);
        Assert.Equal("PASSED", result.Outcome);
    }

    [Fact]
    public void Outcome_IsFailed_WhenFailedAndWarningBothPresent()
    {
        var checks = new[]
        {
            new ValidationCheck("Input file", ValidationCheckStatus.Failed, "Missing"),
            new ValidationCheck("Model", ValidationCheckStatus.Warning, "Will be downloaded")
        };

        var result = CreateResult(checks);

        Assert.False(result.CanStart);
        Assert.True(result.HasWarnings);
        Assert.Equal("FAILED", result.Outcome);
    }

    /// <summary>
    /// Constructs a ValidationResult using the same logic as ValidationService to derive Outcome/CanStart/HasWarnings.
    /// </summary>
    private static ValidationResult CreateResult(ValidationCheck[] checks)
    {
        var canStart = checks.All(c => c.Status != ValidationCheckStatus.Failed);
        var hasWarnings = checks.Any(c => c.Status == ValidationCheckStatus.Warning);
        var outcome = canStart
            ? hasWarnings ? "PASSED WITH WARNINGS" : "PASSED"
            : "FAILED";

        return new ValidationResult(outcome, canStart, hasWarnings, "/test/config.json", checks);
    }
}
