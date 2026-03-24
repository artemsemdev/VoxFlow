using VoxFlow.Core.Models;

namespace VoxFlow.Cli;

/// <summary>
/// Renders startup validation results to the console with color-coded ANSI output.
/// </summary>
internal static class ConsoleValidationReporter
{
    private static readonly bool UseAnsiColors = !Console.IsOutputRedirected;

    /// <summary>
    /// Prints the validation report and a final outcome summary.
    /// </summary>
    public static void Write(ValidationResult result, bool printDetailedReport)
    {
        Console.WriteLine(Colorize("=== Startup Validation ===", "96"));

        if (printDetailedReport)
        {
            foreach (var check in result.Checks)
            {
                var statusLabel = $"[{MapStatus(check.Status)}]";
                Console.WriteLine($"{ColorizeStatus(statusLabel, check.Status)} {check.Name}: {check.Details}");
            }
        }

        var outcomeLabel = ColorizeOutcome(result.Outcome);
        Console.WriteLine(
            $"Startup validation outcome: {outcomeLabel} " +
            $"(passed: {result.Checks.Count(c => c.Status == ValidationCheckStatus.Passed)}, " +
            $"warnings: {result.Checks.Count(c => c.Status == ValidationCheckStatus.Warning)}, " +
            $"failed: {result.Checks.Count(c => c.Status == ValidationCheckStatus.Failed)}, " +
            $"skipped: {result.Checks.Count(c => c.Status == ValidationCheckStatus.Skipped)})");
    }

    private static string MapStatus(ValidationCheckStatus status)
    {
        return status switch
        {
            ValidationCheckStatus.Passed => "PASS",
            ValidationCheckStatus.Warning => "WARN",
            ValidationCheckStatus.Failed => "FAIL",
            ValidationCheckStatus.Skipped => "SKIP",
            _ => status.ToString().ToUpperInvariant()
        };
    }

    private static string ColorizeStatus(string text, ValidationCheckStatus status)
    {
        return status switch
        {
            ValidationCheckStatus.Passed => Colorize(text, "92"),
            ValidationCheckStatus.Warning => Colorize(text, "93"),
            ValidationCheckStatus.Failed => Colorize(text, "91"),
            ValidationCheckStatus.Skipped => Colorize(text, "90"),
            _ => text
        };
    }

    private static string ColorizeOutcome(string outcome)
    {
        return outcome switch
        {
            "PASSED" => Colorize(outcome, "92"),
            "PASSED WITH WARNINGS" => Colorize(outcome, "93"),
            "FAILED" => Colorize(outcome, "91"),
            _ => outcome
        };
    }

    private static string Colorize(string text, string colorCode)
    {
        if (!UseAnsiColors || string.IsNullOrEmpty(text))
        {
            return text;
        }

        return $"\u001b[{colorCode}m{text}\u001b[0m";
    }
}
