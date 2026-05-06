using System;
using System.IO;

/// <summary>
/// Resolves on-disk fixture paths for tests in a portable, fail-loud way:
/// 1. <c>VOXFLOW_TEST_FIXTURES_DIR</c> environment variable wins if set.
/// 2. Otherwise the path is computed relative to the test assembly via
///    <see cref="TestProjectPaths.RepositoryRoot"/>.
/// Tests should pass the result to <see cref="LoudSkip.IfNot"/> with a
/// reason that names the missing path so silent skips never hide a missing
/// fixture from CI.
/// </summary>
internal static class TestFixtureLocator
{
    private const string FixturesDirEnvVar = "VOXFLOW_TEST_FIXTURES_DIR";

    /// <summary>
    /// Resolve a fixture path under the configured fixtures root. Does not
    /// check existence — callers gate on <see cref="File.Exists"/> via
    /// <see cref="LoudSkip"/> so the skip reason includes the resolved path.
    /// </summary>
    public static string Resolve(params string[] segments)
    {
        ArgumentNullException.ThrowIfNull(segments);
        var root = ResolveFixturesRoot();
        return segments.Length == 0
            ? root
            : Path.Combine(new[] { root }.Concat(segments).ToArray());
    }

    /// <summary>
    /// Build a clear skip reason for a missing fixture, including the
    /// resolved path and how to override it via environment variable.
    /// </summary>
    public static string FormatMissingFixtureReason(string resolvedPath)
        => $"fixture not present at {resolvedPath}; set {FixturesDirEnvVar} to point at a directory that contains the expected files.";

    private static string ResolveFixturesRoot()
    {
        var fromEnv = Environment.GetEnvironmentVariable(FixturesDirEnvVar);
        if (!string.IsNullOrWhiteSpace(fromEnv))
        {
            return fromEnv;
        }

        // Default: <repo>/artifacts/Input — the location the original
        // hardcoded paths used. Keeping it as the default means a clean
        // checkout with the optional fixture set still finds the files
        // without any env-var ceremony, while CI machines that lack the
        // fixtures get a clear loud-skip message instead of a confusing
        // "file not found" assertion.
        return Path.Combine(TestProjectPaths.RepositoryRoot, "artifacts", "Input");
    }
}
