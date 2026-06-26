using System;
using VoxFlow.Cli;
using Xunit;

namespace VoxFlow.Cli.Tests;

public sealed class CliRouterTests
{
    [Fact]
    public void NoArgs_RoutesToTranscribe_WithNoArgs()
    {
        var route = CliRouter.Route(Array.Empty<string>());
        Assert.Equal(CliVerb.Transcribe, route.Verb);
        Assert.Empty(route.Args);
    }

    [Theory]
    [InlineData("--speakers")]
    [InlineData("--no-speakers")]
    [InlineData("--help")]
    [InlineData("--speakers=false")]
    public void LeadingFlag_RoutesToTranscribe_Implicitly_PreservingArgs(string flag)
    {
        // Backward compatibility: `voxflow --speakers` must keep working as transcribe.
        var route = CliRouter.Route(new[] { flag });
        Assert.Equal(CliVerb.Transcribe, route.Verb);
        Assert.Equal(new[] { flag }, route.Args);
    }

    [Fact]
    public void ExplicitTranscribe_StripsVerb_KeepsRemainingArgs()
    {
        var route = CliRouter.Route(new[] { "transcribe", "--speakers" });
        Assert.Equal(CliVerb.Transcribe, route.Verb);
        Assert.Equal(new[] { "--speakers" }, route.Args);
    }

    [Fact]
    public void Doctor_RoutesToDoctor_WithSubArgs()
    {
        var route = CliRouter.Route(new[] { "doctor", "speakers" });
        Assert.Equal(CliVerb.Doctor, route.Verb);
        Assert.Equal(new[] { "speakers" }, route.Args);
    }

    [Fact]
    public void Setup_RoutesToSetup_WithSubArgs()
    {
        var route = CliRouter.Route(new[] { "setup", "speakers" });
        Assert.Equal(CliVerb.Setup, route.Verb);
        Assert.Equal(new[] { "speakers" }, route.Args);
    }

    [Theory]
    [InlineData("TRANSCRIBE", "Transcribe")]
    [InlineData("Doctor", "Doctor")]
    [InlineData("SETUP", "Setup")]
    public void Verbs_AreCaseInsensitive(string verb, string expected)
    {
        var route = CliRouter.Route(new[] { verb });
        Assert.Equal(expected, route.Verb.ToString());
    }

    [Fact]
    public void UnknownVerb_Throws_WithActionableMessage()
    {
        var ex = Assert.Throws<ArgumentException>(() => CliRouter.Route(new[] { "frobnicate" }));
        Assert.Contains("frobnicate", ex.Message);
        Assert.Contains("transcribe", ex.Message);
        Assert.Contains("doctor", ex.Message);
        Assert.Contains("setup", ex.Message);
    }
}
