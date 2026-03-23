#nullable enable
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Wraps StartupValidationService to return structured DTOs suitable for MCP and programmatic consumption.
/// </summary>
internal sealed class StartupValidationFacade : IStartupValidationFacade
{
    public async Task<StartupValidationResultDto> ValidateAsync(
        string? configurationPath = null,
        CancellationToken cancellationToken = default)
    {
        var options = LoadOptions(configurationPath);
        var report = await StartupValidationService.ValidateAsync(options, cancellationToken)
            .ConfigureAwait(false);

        var checks = report.Results
            .Select(r => new StartupCheckDto(r.Name, r.Status.ToString(), r.Details))
            .ToArray();

        return new StartupValidationResultDto(
            Outcome: report.Outcome,
            CanStart: report.CanStart,
            HasWarnings: report.HasWarnings,
            ResolvedConfigurationPath: options.ConfigurationPath,
            Checks: checks);
    }

    private static TranscriptionOptions LoadOptions(string? configurationPath)
    {
        return string.IsNullOrWhiteSpace(configurationPath)
            ? TranscriptionOptions.Load()
            : TranscriptionOptions.LoadFromPath(configurationPath);
    }
}
