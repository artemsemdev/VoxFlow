#nullable enable
using System;
using System.IO;
using VoxFlow.McpServer.Security;
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
    public void ValidateInputPath_AcceptsPathMatchingAllowedRootExactly()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(inputRoots: new[] { tempDir });

        policy.ValidateInputPath(tempDir);
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
    public void ValidateOutputPath_AcceptsPathMatchingAllowedRootExactly()
    {
        var tempDir = Path.GetTempPath();
        var policy = CreatePolicy(outputRoots: new[] { tempDir });

        policy.ValidateOutputPath(tempDir);
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
    public void ValidateInputPath_RejectsNullByteInjection_AsUnauthorized()
    {
        var policy = CreatePolicy(inputRoots: new[] { "/allowed/input" });

        // A null byte is a classic path-truncation injection; it must be rejected
        // explicitly as a policy violation, not leak through as a generic IO error.
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateInputPath("/allowed/input/clip\0.m4a"));
    }

    [Fact]
    public void ValidateOutputPath_RejectsNullByteInjection_AsUnauthorized()
    {
        var policy = CreatePolicy(outputRoots: new[] { "/allowed/output" });

        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateOutputPath("/allowed/output/result\0.txt"));
    }

    [Theory]
    [InlineData("/tmp/audio", "/tmp/audio-other/clip.m4a")]
    [InlineData("/tmp/audio", "/tmp/audioevil")]
    public void ValidateInputPath_RejectsRootPrefixAttack(string root, string attacker)
    {
        var policy = CreatePolicy(inputRoots: new[] { root });

        // `/tmp/audio-other` shares a string prefix with `/tmp/audio` but is NOT
        // under it; the trailing-separator normalization must keep them distinct.
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateInputPath(attacker));
    }

    [Fact]
    public void ValidateInputPath_AcceptsSiblingSuffixUnderSameRoot()
    {
        // Guard the prefix fix against false positives: a real child whose name
        // starts with the root's last segment must still be accepted.
        var policy = CreatePolicy(inputRoots: new[] { "/tmp/audio" });
        policy.ValidateInputPath("/tmp/audio/audio-2.m4a");
    }

    [Fact]
    public void ValidateOutputPath_RejectsParentTraversalEscapingRoot()
    {
        var policy = CreatePolicy(outputRoots: new[] { "/allowed/output" });

        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateOutputPath("/allowed/output/../../etc/evil.txt"));
    }

    [Fact]
    public void ValidateInputPath_CaseSensitivity_MatchesHostFileSystem()
    {
        var tempDir = TrimSeparator(Path.GetTempPath());
        var policy = CreatePolicy(inputRoots: new[] { tempDir });
        var differentCase = Path.Combine(tempDir.ToUpperInvariant(), "clip.m4a");

        if (OperatingSystem.IsLinux())
        {
            // Linux filesystems are case-sensitive: a differently-cased path is a
            // different location and must not satisfy the allowed root.
            Assert.Throws<UnauthorizedAccessException>(() =>
                policy.ValidateInputPath(differentCase));
        }
        else
        {
            // Windows and the default macOS volume are case-insensitive.
            policy.ValidateInputPath(differentCase);
        }
    }

    private static string TrimSeparator(string path) =>
        path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

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
