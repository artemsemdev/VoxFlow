using System.Collections.Generic;
using Xunit;
using Xunit.Abstractions;

namespace VoxFlow.Core.Tests.TestSupport;

public sealed class LoudSkipTests
{
    [Fact]
    public void IfNot_ConditionFalse_LogsReason_AndThrowsSkip()
    {
        var fake = new RecordingTestOutputHelper();

        var ex = Assert.Throws<SkipException>(() =>
            LoudSkip.IfNot(fake, condition: false, reason: "missing fixture"));

        Assert.Contains("[SKIP] missing fixture", fake.Lines);
        Assert.Equal("missing fixture", ex.Message);
    }

    [Fact]
    public void IfNot_ConditionTrue_NoOutput_NoThrow()
    {
        var fake = new RecordingTestOutputHelper();

        LoudSkip.IfNot(fake, condition: true, reason: "should not appear");

        Assert.Empty(fake.Lines);
    }

    [Fact]
    public void If_ConditionTrue_LogsReason_AndThrowsSkip()
    {
        var fake = new RecordingTestOutputHelper();

        var ex = Assert.Throws<SkipException>(() =>
            LoudSkip.If(fake, condition: true, reason: "bundle absent"));

        Assert.Contains("[SKIP] bundle absent", fake.Lines);
        Assert.Equal("bundle absent", ex.Message);
    }

    [Fact]
    public void If_ConditionFalse_NoOutput_NoThrow()
    {
        var fake = new RecordingTestOutputHelper();

        LoudSkip.If(fake, condition: false, reason: "should not appear");

        Assert.Empty(fake.Lines);
    }

    private sealed class RecordingTestOutputHelper : ITestOutputHelper
    {
        public List<string> Lines { get; } = new();

        public void WriteLine(string message) => Lines.Add(message);

        public void WriteLine(string format, params object[] args)
            => Lines.Add(string.Format(format, args));
    }
}
