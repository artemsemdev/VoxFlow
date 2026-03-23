using Xunit;

public sealed class StartupValidationReportTests
{
    [Fact]
    public void Outcome_IsPassedWithWarnings_WhenThereAreWarningsAndNoFailures()
    {
        var report = new StartupValidationReport(
            [
                StartupCheckResult.Passed("Settings", "OK"),
                StartupCheckResult.Warning("Model", "Will be downloaded")
            ]);

        Assert.True(report.CanStart);
        Assert.True(report.HasWarnings);
        Assert.Equal("PASSED WITH WARNINGS", report.Outcome);
    }

    [Fact]
    public void Outcome_IsFailed_WhenAnyCheckFails()
    {
        var report = new StartupValidationReport(
            [
                StartupCheckResult.Passed("Settings", "OK"),
                StartupCheckResult.Failed("Input file", "Missing")
            ]);

        Assert.False(report.CanStart);
        Assert.Equal("FAILED", report.Outcome);
    }

    [Fact]
    public void Outcome_IsPassed_WhenAllChecksPassed()
    {
        var report = new StartupValidationReport(
            [
                StartupCheckResult.Passed("Settings", "OK"),
                StartupCheckResult.Passed("Input file", "Found"),
                StartupCheckResult.Passed("ffmpeg", "Available")
            ]);

        Assert.True(report.CanStart);
        Assert.False(report.HasWarnings);
        Assert.Equal("PASSED", report.Outcome);
    }

    [Fact]
    public void Outcome_IsPassed_WhenOnlySkippedAndPassed()
    {
        var report = new StartupValidationReport(
            [
                StartupCheckResult.Passed("Settings", "OK"),
                StartupCheckResult.Skipped("Whisper runtime", "Disabled by configuration.")
            ]);

        Assert.True(report.CanStart);
        Assert.False(report.HasWarnings);
        Assert.Equal("PASSED", report.Outcome);
    }

    [Fact]
    public void Outcome_IsFailed_WhenFailedAndWarningBothPresent()
    {
        var report = new StartupValidationReport(
            [
                StartupCheckResult.Failed("Input file", "Missing"),
                StartupCheckResult.Warning("Model", "Will be downloaded")
            ]);

        Assert.False(report.CanStart);
        Assert.True(report.HasWarnings);
        Assert.Equal("FAILED", report.Outcome);
    }
}
