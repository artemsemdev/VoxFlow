#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace VoxFlow.McpServer.Security;

/// <summary>
/// Enforces file access restrictions based on configured allowed roots.
/// </summary>
internal sealed class PathPolicy : IPathPolicy
{
    /// <summary>
    /// How paths are compared against allowed roots. Linux filesystems are
    /// case-sensitive, so <c>/Home</c> and <c>/home</c> are genuinely different
    /// locations and a case-insensitive compare would let an attacker satisfy a
    /// root by changing case. Windows and the default macOS volume are
    /// case-insensitive, so we match their behavior there. This is intentional
    /// per-OS behavior — see PathPolicyTests.ValidateInputPath_CaseSensitivity_MatchesHostFileSystem.
    /// </summary>
    internal static readonly StringComparison PathComparison =
        RuntimeInformation.IsOSPlatform(OSPlatform.Linux)
            ? StringComparison.Ordinal
            : StringComparison.OrdinalIgnoreCase;

    private readonly IReadOnlyList<string> allowedInputRoots;
    private readonly IReadOnlyList<string> allowedOutputRoots;
    private readonly bool requireAbsolutePaths;

    public PathPolicy(
        IReadOnlyList<string> allowedInputRoots,
        IReadOnlyList<string> allowedOutputRoots,
        bool requireAbsolutePaths = true)
    {
        ArgumentNullException.ThrowIfNull(allowedInputRoots);
        ArgumentNullException.ThrowIfNull(allowedOutputRoots);

        this.allowedInputRoots = NormalizeRoots(allowedInputRoots);
        this.allowedOutputRoots = NormalizeRoots(allowedOutputRoots);
        this.requireAbsolutePaths = requireAbsolutePaths;
    }

    public void ValidateInputPath(string path)
    {
        ValidatePathBasics(path);

        if (allowedInputRoots.Count > 0 && !IsUnderAnyRoot(path, allowedInputRoots))
        {
            throw new UnauthorizedAccessException(
                $"Path is not under any allowed input root: {SanitizePath(path)}");
        }
    }

    public void ValidateOutputPath(string path)
    {
        ValidatePathBasics(path);

        if (allowedOutputRoots.Count > 0 && !IsUnderAnyRoot(path, allowedOutputRoots))
        {
            throw new UnauthorizedAccessException(
                $"Path is not under any allowed output root: {SanitizePath(path)}");
        }
    }

    public bool IsAllowedInputPath(string path)
    {
        try
        {
            ValidateInputPath(path);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    public bool IsAllowedOutputPath(string path)
    {
        try
        {
            ValidateOutputPath(path);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void ValidatePathBasics(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("Path must not be empty.");
        }

        // Reject traversal / null-byte injection up front, before any normalization.
        // Doing this first means a null byte is reported as an explicit policy
        // violation instead of leaking through as a generic IO ArgumentException
        // from Path.GetFullPath.
        if (ContainsDangerousSegments(path))
        {
            throw new UnauthorizedAccessException(
                $"Path contains traversal or injection sequences: {SanitizePath(path)}");
        }

        if (requireAbsolutePaths && !Path.IsPathRooted(path))
        {
            throw new ArgumentException($"Path must be absolute: {SanitizePath(path)}");
        }
    }

    private static bool IsUnderAnyRoot(string path, IReadOnlyList<string> roots)
    {
        // Resolve symlinks before the root check so a link inside an allowed root
        // that points outside it cannot satisfy the prefix test. Roots were
        // canonicalized the same way in NormalizeRoots, so both sides compare in
        // their real-path form.
        var normalizedPath = TrimTrailingDirectorySeparator(ResolveRealPath(path));
        return roots.Any(root =>
        {
            var normalizedRoot = TrimTrailingDirectorySeparator(root);
            return normalizedPath.Equals(normalizedRoot, PathComparison)
                   || normalizedPath.StartsWith(root, PathComparison);
        });
    }

    private static bool ContainsDangerousSegments(string path)
    {
        return path.Contains("..") ||
               path.Contains("~") ||
               path.Contains('\0');
    }

    private static IReadOnlyList<string> NormalizeRoots(IReadOnlyList<string> roots)
    {
        return roots
            .Where(r => !string.IsNullOrWhiteSpace(r))
            .Select(r =>
            {
                // Canonicalize the root (resolving symlinks) so a configured root
                // that is itself a symlink still matches files reached through it.
                var normalized = ResolveRealPath(r);
                // Force a trailing separator so `/allowed-audio-2` does not satisfy a root of `/allowed-audio`.
                return normalized.EndsWith(Path.DirectorySeparatorChar)
                    ? normalized
                    : normalized + Path.DirectorySeparatorChar;
            })
            .ToArray();
    }

    /// <summary>
    /// Canonicalizes a path by resolving symbolic links on the longest existing
    /// prefix and re-appending any trailing components that do not exist yet
    /// (realpath -m semantics). This is what closes the symlink-escape gap: a
    /// symlink inside an allowed root that points outside it resolves to its real
    /// location before the root check. Resolution failures (e.g. symlink cycles)
    /// degrade safely to the non-resolved full path, which is still checked.
    /// </summary>
    internal static string ResolveRealPath(string path)
    {
        var full = Path.GetFullPath(path);

        // Walk up to the nearest existing ancestor, collecting the trailing
        // components that do not exist on disk (e.g. an output file not yet
        // written, or a path under a broken symlink).
        var existing = full;
        var trailing = new List<string>();
        while (!Path.Exists(existing))
        {
            var parent = Path.GetDirectoryName(existing);
            if (string.IsNullOrEmpty(parent) || parent == existing)
            {
                // Nothing along the path exists; there is nothing to resolve.
                return full;
            }

            trailing.Add(Path.GetFileName(existing));
            existing = parent;
        }

        string resolvedExisting;
        try
        {
            resolvedExisting = ResolveExisting(existing);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // e.g. a symlink cycle. Fail safe by not resolving; the unresolved
            // path is still subjected to the allowed-root check.
            return full;
        }

        if (trailing.Count == 0)
        {
            return resolvedExisting;
        }

        trailing.Reverse();
        var combined = new string[trailing.Count + 1];
        combined[0] = resolvedExisting;
        trailing.CopyTo(combined, 1);
        return Path.GetFullPath(Path.Combine(combined));
    }

    /// <summary>
    /// Resolves every symbolic link in an existing path component by component,
    /// so intermediate directory symlinks are followed, not just the leaf. When a
    /// component is a link, its (already chain-resolved) target is canonicalized
    /// recursively — that is what keeps an absolute target from re-introducing an
    /// unresolved ancestor symlink (e.g. macOS <c>/var</c> -> <c>/private/var</c>).
    /// </summary>
    private static string ResolveExisting(string existingPath, int depth = 0)
    {
        // Bound recursion so a pathological symlink graph degrades to a thrown
        // IOException (caught and failed-safe by ResolveRealPath) instead of a
        // stack overflow.
        if (depth > 40)
        {
            throw new IOException("Too many levels of symbolic links.");
        }

        var pathRoot = Path.GetPathRoot(existingPath);
        var current = string.IsNullOrEmpty(pathRoot)
            ? Path.DirectorySeparatorChar.ToString()
            : pathRoot;
        var remainder = existingPath.Substring(current.Length);

        foreach (var component in remainder.Split(
                     new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            FileSystemInfo info = Directory.Exists(current)
                ? new DirectoryInfo(current)
                : new FileInfo(current);

            // Use the raw LinkTarget (one hop, may be relative) rather than
            // ResolveLinkTarget(returnFinalTarget: true): the latter THROWS on a
            // dangling link, whereas reading the raw target lets us resolve the
            // link by its declared destination even when the target is missing.
            // Recursion below follows multi-hop chains and resolves any ancestor
            // symlinks in the target (e.g. macOS /var -> /private/var).
            var linkTarget = info.LinkTarget;
            if (linkTarget is not null)
            {
                var linkDirectory = Path.GetDirectoryName(current) ?? current;
                var absoluteTarget = Path.IsPathRooted(linkTarget)
                    ? linkTarget
                    : Path.Combine(linkDirectory, linkTarget);
                current = ResolveExisting(Path.GetFullPath(absoluteTarget), depth + 1);
            }
        }

        return current;
    }

    private static string TrimTrailingDirectorySeparator(string path)
    {
        var root = Path.GetPathRoot(path);
        return string.Equals(path, root, StringComparison.Ordinal)
            ? path
            : path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    /// <summary>
    /// Returns a sanitized version of a path for error messages to avoid leaking full paths.
    /// </summary>
    internal static string SanitizePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return "(empty)";
        }

        // Show just the filename or last segment for security.
        var fileName = Path.GetFileName(path);
        return string.IsNullOrWhiteSpace(fileName) ? "(directory)" : $".../{fileName}";
    }
}
