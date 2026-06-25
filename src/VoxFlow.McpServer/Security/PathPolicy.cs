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
        var normalizedPath = TrimTrailingDirectorySeparator(Path.GetFullPath(path));
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
                var normalized = Path.GetFullPath(r);
                // Force a trailing separator so `/allowed-audio-2` does not satisfy a root of `/allowed-audio`.
                return normalized.EndsWith(Path.DirectorySeparatorChar)
                    ? normalized
                    : normalized + Path.DirectorySeparatorChar;
            })
            .ToArray();
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
