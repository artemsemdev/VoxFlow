#nullable enable
using System;
using System.IO;
using VoxFlow.McpServer.Security;
using Xunit;

/// <summary>
/// Symlink-aware path policy tests (#85). Each test builds a real directory tree
/// with symlinks under a throwaway temp root, so they exercise actual filesystem
/// resolution rather than string manipulation. Skipped where the filesystem does
/// not allow creating symbolic links (e.g. unprivileged Windows).
/// </summary>
public sealed class PathPolicySymlinkTests : IDisposable
{
    private readonly string work;
    private readonly bool symlinksSupported;

    public PathPolicySymlinkTests()
    {
        work = Directory.CreateDirectory(
            Path.Combine(Path.GetTempPath(), "voxflow-symlink-" + Guid.NewGuid().ToString("N"))).FullName;
        symlinksSupported = ProbeSymlinkSupport(work);
    }

    public void Dispose()
    {
        try { Directory.Delete(work, recursive: true); }
        catch { /* best-effort cleanup */ }
    }

    [SkippableFact]
    public void ValidateInputPath_RejectsSymlinkInsideRoot_EscapingToOutsideFile()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var root = Directory.CreateDirectory(Path.Combine(work, "allowed")).FullName;
        var outside = Directory.CreateDirectory(Path.Combine(work, "outside")).FullName;
        File.WriteAllText(Path.Combine(outside, "secret.txt"), "top secret");

        // A symlink that lives inside the allowed root but points outside it.
        var escape = Path.Combine(root, "escape");
        Directory.CreateSymbolicLink(escape, outside);

        var policy = new PathPolicy(new[] { root }, Array.Empty<string>());

        // /allowed/escape/secret.txt resolves to /outside/secret.txt — must be denied.
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateInputPath(Path.Combine(escape, "secret.txt")));
    }

    [SkippableFact]
    public void ValidateOutputPath_RejectsSymlinkedDirEscapingRoot()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var root = Directory.CreateDirectory(Path.Combine(work, "out-allowed")).FullName;
        var outside = Directory.CreateDirectory(Path.Combine(work, "out-outside")).FullName;

        var escape = Path.Combine(root, "escape");
        Directory.CreateSymbolicLink(escape, outside);

        var policy = new PathPolicy(Array.Empty<string>(), new[] { root });

        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateOutputPath(Path.Combine(escape, "result.txt")));
    }

    [SkippableFact]
    public void ValidateInputPath_AllowsSymlinkResolvingWithinRoot()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var root = Directory.CreateDirectory(Path.Combine(work, "allowed")).FullName;
        var realSub = Directory.CreateDirectory(Path.Combine(root, "real-sub")).FullName;
        File.WriteAllText(Path.Combine(realSub, "clip.m4a"), "audio");

        var link = Path.Combine(root, "link");
        Directory.CreateSymbolicLink(link, realSub);

        var policy = new PathPolicy(new[] { root }, Array.Empty<string>());

        // Symlink stays inside the root — must remain allowed.
        policy.ValidateInputPath(Path.Combine(link, "clip.m4a"));
    }

    [SkippableFact]
    public void ValidateInputPath_AllowsFileUnderSymlinkedRoot()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var realRoot = Directory.CreateDirectory(Path.Combine(work, "real-audio")).FullName;
        File.WriteAllText(Path.Combine(realRoot, "clip.m4a"), "audio");

        // The configured root is itself a symlink to the real directory.
        var linkRoot = Path.Combine(work, "audio-link");
        Directory.CreateSymbolicLink(linkRoot, realRoot);

        var policy = new PathPolicy(new[] { linkRoot }, Array.Empty<string>());

        // A file under the symlinked root must still be accepted.
        policy.ValidateInputPath(Path.Combine(linkRoot, "clip.m4a"));
    }

    [SkippableFact]
    public void ValidateInputPath_RejectsDanglingSymlinkPointingOutsideRoot()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var root = Directory.CreateDirectory(Path.Combine(work, "allowed")).FullName;
        var dangling = Path.Combine(root, "dangling");
        // Broken symlink: the target does not exist and is outside the root.
        Directory.CreateSymbolicLink(dangling, Path.Combine(work, "does-not-exist"));

        var policy = new PathPolicy(new[] { root }, Array.Empty<string>());

        // Even though the target is missing, the link resolves to a location
        // outside the allowed root, so it must be denied — a broken symlink must
        // not become a loophole for referencing outside the root.
        Assert.Throws<UnauthorizedAccessException>(() =>
            policy.ValidateInputPath(Path.Combine(dangling, "x.txt")));
    }

    [SkippableFact]
    public void ValidateInputPath_AllowsDanglingSymlinkPointingInsideRoot()
    {
        Skip.IfNot(symlinksSupported, "Filesystem does not support symbolic links.");

        var root = Directory.CreateDirectory(Path.Combine(work, "allowed")).FullName;
        var dangling = Path.Combine(root, "dangling");
        // Broken symlink whose (missing) target is still inside the root.
        Directory.CreateSymbolicLink(dangling, Path.Combine(root, "not-yet-created"));

        var policy = new PathPolicy(new[] { root }, Array.Empty<string>());

        // Resolves to a location under the root, so it is allowed; a later read
        // fails safely because the target does not exist.
        policy.ValidateInputPath(Path.Combine(dangling, "x.txt"));
    }

    private static bool ProbeSymlinkSupport(string dir)
    {
        var link = Path.Combine(dir, "probe-link");
        var target = Path.Combine(dir, "probe-target");
        try
        {
            Directory.CreateDirectory(target);
            Directory.CreateSymbolicLink(link, target);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            return false;
        }
        finally
        {
            try { Directory.Delete(link); } catch { /* ignore */ }
            try { Directory.Delete(target); } catch { /* ignore */ }
        }
    }
}
