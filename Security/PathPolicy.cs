#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

/// <summary>
/// Validates file paths against configured allowed roots.
/// </summary>
internal interface IPathPolicy
{
    /// <summary>
    /// Validates that a path is safe for reading input files.
    /// </summary>
    void ValidateInputPath(string path);

    /// <summary>
    /// Validates that a path is safe for writing output files.
    /// </summary>
    void ValidateOutputPath(string path);

    /// <summary>
    /// Returns true if the path is within allowed input roots.
    /// </summary>
    bool IsAllowedInputPath(string path);

    /// <summary>
    /// Returns true if the path is within allowed output roots.
    /// </summary>
    bool IsAllowedOutputPath(string path);
}

/// <summary>
/// Enforces file access restrictions based on configured allowed roots.
/// </summary>
internal sealed class PathPolicy : IPathPolicy
{
    private readonly IReadOnlyList<string> allowedInputRoots;
    private readonly IReadOnlyList<string> allowedOutputRoots;
    private readonly bool requireAbsolutePaths;

    public PathPolicy(
        IReadOnlyList<string> allowedInputRoots,
        IReadOnlyList<string> allowedOutputRoots,
        bool requireAbsolutePaths = true)
    {
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
        catch
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
        catch
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

        if (requireAbsolutePaths && !Path.IsPathRooted(path))
        {
            throw new ArgumentException($"Path must be absolute: {SanitizePath(path)}");
        }

        var normalized = Path.GetFullPath(path);

        // Reject path traversal attempts.
        if (normalized != path && ContainsTraversalSegments(path))
        {
            throw new UnauthorizedAccessException(
                $"Path contains traversal sequences: {SanitizePath(path)}");
        }
    }

    private static bool IsUnderAnyRoot(string path, IReadOnlyList<string> roots)
    {
        var normalized = Path.GetFullPath(path);
        return roots.Any(root => normalized.StartsWith(root, StringComparison.OrdinalIgnoreCase));
    }

    private static bool ContainsTraversalSegments(string path)
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
                return normalized.EndsWith(Path.DirectorySeparatorChar)
                    ? normalized
                    : normalized + Path.DirectorySeparatorChar;
            })
            .ToArray();
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
