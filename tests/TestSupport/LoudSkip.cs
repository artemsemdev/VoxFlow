using System.Diagnostics.CodeAnalysis;
using Xunit;
using Xunit.Abstractions;

/// <summary>
/// Wrapper around <see cref="Skip.IfNot(bool, string)"/> / <see cref="Skip.If(bool, string)"/>
/// that emits the skip reason to the xUnit test output sink before the underlying
/// <see cref="SkipException"/> is raised. Plain Skip.IfNot/If only surface the reason
/// at xUnit-detailed verbosity, so on default-verbosity CI runs silent skips look
/// like passing tests. Logging upfront keeps the reason visible regardless of verbosity.
/// The DoesNotReturnIf attributes preserve the null-flow analysis callers get from
/// the underlying Skip helpers (e.g. "after LoudSkip.If(x is null, ...) the value is
/// known non-null").
/// </summary>
internal static class LoudSkip
{
    public static void IfNot(ITestOutputHelper output, [DoesNotReturnIf(false)] bool condition, string reason)
    {
        if (!condition)
        {
            output.WriteLine($"[SKIP] {reason}");
        }
        Skip.IfNot(condition, reason);
    }

    public static void If(ITestOutputHelper output, [DoesNotReturnIf(true)] bool condition, string reason)
    {
        if (condition)
        {
            output.WriteLine($"[SKIP] {reason}");
        }
        Skip.If(condition, reason);
    }
}
