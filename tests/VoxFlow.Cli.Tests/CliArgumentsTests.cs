using System;
using VoxFlow.Cli;
using Xunit;

namespace VoxFlow.Cli.Tests;

public sealed class CliArgumentsTests
{
    [Fact]
    public void Parse_NoArgs_ReturnsNullEnableSpeakers_AndShowHelpFalse()
    {
        var args = CliArguments.Parse(Array.Empty<string>());

        Assert.Null(args.EnableSpeakers);
        Assert.False(args.ShowHelp);
    }

    [Fact]
    public void Parse_SpeakersFlag_SetsEnableSpeakersTrue()
    {
        var args = CliArguments.Parse(["--speakers"]);

        Assert.True(args.EnableSpeakers);
    }

    [Fact]
    public void Parse_SpeakersEqualsTrue_SetsEnableSpeakersTrue()
    {
        var args = CliArguments.Parse(["--speakers=true"]);

        Assert.True(args.EnableSpeakers);
    }

    [Fact]
    public void Parse_SpeakersEqualsFalse_SetsEnableSpeakersFalse()
    {
        var args = CliArguments.Parse(["--speakers=false"]);

        Assert.False(args.EnableSpeakers);
    }

    [Fact]
    public void Parse_SpeakersEqualsMixedCase_IsAccepted()
    {
        var trueArgs = CliArguments.Parse(["--speakers=TRUE"]);
        var falseArgs = CliArguments.Parse(["--speakers=False"]);

        Assert.True(trueArgs.EnableSpeakers);
        Assert.False(falseArgs.EnableSpeakers);
    }

    [Fact]
    public void Parse_SpeakersEqualsBogusValue_Throws_AndMessageMentionsFlag()
    {
        var ex = Assert.Throws<ArgumentException>(
            () => CliArguments.Parse(["--speakers=maybe"]));

        Assert.Contains("--speakers=maybe", ex.Message);
    }

    [Fact]
    public void Parse_NoSpeakers_SetsEnableSpeakersFalse()
    {
        var args = CliArguments.Parse(["--no-speakers"]);

        Assert.False(args.EnableSpeakers);
    }

    [Fact]
    public void Parse_HelpFlag_SetsShowHelpTrue()
    {
        var args = CliArguments.Parse(["--help"]);

        Assert.True(args.ShowHelp);
    }

    [Fact]
    public void Parse_UnknownFlag_Throws_AndMessageMentionsFlag()
    {
        var ex = Assert.Throws<ArgumentException>(
            () => CliArguments.Parse(["--bogus"]));

        Assert.Contains("--bogus", ex.Message);
    }

    [Fact]
    public void Parse_ConflictingFlags_LastWins()
    {
        var lastFalse = CliArguments.Parse(["--speakers", "--no-speakers"]);
        var lastTrue = CliArguments.Parse(["--no-speakers", "--speakers"]);

        Assert.False(lastFalse.EnableSpeakers);
        Assert.True(lastTrue.EnableSpeakers);
    }

    [Fact]
    public void HelpText_MentionsEverySupportedFlag()
    {
        var help = CliArguments.HelpText;

        Assert.Contains("--speakers", help);
        Assert.Contains("--no-speakers", help);
        Assert.Contains("--help", help);
    }

    [Fact]
    public void HelpText_ListsEveryVerb()
    {
        var help = CliArguments.HelpText;

        Assert.Contains("transcribe", help);
        Assert.Contains("doctor", help);
        Assert.Contains("setup", help);
    }
}
