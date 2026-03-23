#nullable enable
using System;
using System.IO;
using Xunit;

public sealed class PathPolicyTests
{
    [Fact]
    public void ValidateInputPath_RejectsEmptyPath()
    {
        var policy = CreatePolicy();
        Assert.Throws<ArgumentException>(() => policy.ValidateInputPath(""));
    }

    [Fact]
    public void ValidateInputPath_RejectsNullPath()
    {
        var policy = CreatePolicy();
        Assert.Throws<ArgumentException>(() => policy.ValidateInputPath(null!));
    }

    [Fact]
    public void ValidateInputPath_RejectsRelativePath_WhenAbsoluteRequired()
    {
        var policy = CreatePolicy(requireAbsolutePaths: true);
        Assert.Throws<ArgumentException>(() => policy.ValidateInputPath("relative/path.m4a"));
    }

    [Fact]
    public void ValidateInputPath_AcceptsAbsolutePath_UnderAllowedRoot()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(inputRoots: new[] { tempDir });
        var path = Path.Combine(tempDir, "test.m4a");

        // Should not throw.
        policy.ValidateInputPath(path);
    }

    [Fact]
    public void ValidateInputPath_RejectsAbsolutePath_OutsideAllowedRoots()
    {
        var policy = CreatePolicy(inputRoots: new[] { "/allowed/input" });
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateInputPath("/not-allowed/test.m4a"));
    }

    [Fact]
    public void ValidateInputPath_AcceptsAnyAbsolutePath_WhenNoRootsConfigured()
    {
        var policy = CreatePolicy(inputRoots: Array.Empty<string>());
        var path = Path.Combine(Path.GetTempPath(), "test.m4a");

        // No roots = no restriction. Should not throw.
        policy.ValidateInputPath(path);
    }

    [Fact]
    public void ValidateOutputPath_RejectsPathOutsideAllowedRoots()
    {
        var policy = CreatePolicy(outputRoots: new[] { "/allowed/output" });
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateOutputPath("/not-allowed/result.txt"));
    }

    [Fact]
    public void ValidateOutputPath_AcceptsPathUnderAllowedRoot()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(outputRoots: new[] { tempDir });
        var path = Path.Combine(tempDir, "result.txt");

        // Should not throw.
        policy.ValidateOutputPath(path);
    }

    [Fact]
    public void IsAllowedInputPath_ReturnsTrueForAllowedPath()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(inputRoots: new[] { tempDir });
        var path = Path.Combine(tempDir, "test.m4a");

        Assert.True(policy.IsAllowedInputPath(path));
    }

    [Fact]
    public void IsAllowedInputPath_ReturnsFalseForDisallowedPath()
    {
        var policy = CreatePolicy(inputRoots: new[] { "/allowed/input" });
        Assert.False(policy.IsAllowedInputPath("/not-allowed/test.m4a"));
    }

    [Fact]
    public void IsAllowedOutputPath_ReturnsTrueForAllowedPath()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(outputRoots: new[] { tempDir });
        var path = Path.Combine(tempDir, "result.txt");

        Assert.True(policy.IsAllowedOutputPath(path));
    }

    [Fact]
    public void IsAllowedOutputPath_ReturnsFalseForDisallowedPath()
    {
        var policy = CreatePolicy(outputRoots: new[] { "/allowed/output" });
        Assert.False(policy.IsAllowedOutputPath("/not-allowed/result.txt"));
    }

    [Fact]
    public void ValidateInputPath_RejectsPathWithTraversalSegments()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(inputRoots: new[] { tempDir });
        var traversalPath = Path.Combine(tempDir, "..", "etc", "passwd");

        // Should reject because of traversal.
        Assert.ThrowsAny<Exception>(() => policy.ValidateInputPath(traversalPath));
    }

    [Fact]
    public void SanitizePath_ReturnsFileNameOnly()
    {
        var sanitized = PathPolicy.SanitizePath("/some/secret/path/file.txt");
        Assert.Equal(".../file.txt", sanitized);
    }

    [Fact]
    public void SanitizePath_HandlesEmptyPath()
    {
        Assert.Equal("(empty)", PathPolicy.SanitizePath(""));
        Assert.Equal("(empty)", PathPolicy.SanitizePath(null!));
    }

    private static PathPolicy CreatePolicy(
        string[]? inputRoots = null,
        string[]? outputRoots = null,
        bool requireAbsolutePaths = true)
    {
        return new PathPolicy(
            inputRoots ?? Array.Empty<string>(),
            outputRoots ?? Array.Empty<string>(),
            requireAbsolutePaths);
    }
}
