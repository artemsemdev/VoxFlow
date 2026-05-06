using Xunit;
using Xunit.Abstractions;

/// <summary>
/// Wrapper around <see cref="Skip.IfNot(bool, string)"/> / <see cref="Skip.If(bool, string)"/>
/// that emits the skip reason to the xUnit test output sink before the underlying
/// <see cref="SkipException"/> is raised. Plain Skip.IfNot/If only surface the reason
/// at xUnit-detailed verbosity, so on default-verbosity CI runs silent skips look
/// like passing tests. Logging upfront keeps the reason visible regardless of verbosity.
/// </summary>
internal static class LoudSkip
{
    public static void IfNot(ITestOutputHelper output, bool condition, string reason)
    {
        if (!condition)
        {
            output.WriteLine($"[SKIP] {reason}");
        }
        Skip.IfNot(condition, reason);
    }

    public static void If(ITestOutputHelper output, bool condition, string reason)
    {
        if (condition)
        {
            output.WriteLine($"[SKIP] {reason}");
        }
        Skip.If(condition, reason);
    }
}
