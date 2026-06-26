using System;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;

namespace VoxFlow.Cli;

/// <summary>Renders and runs the <c>voxflow doctor speakers</c> health check.</summary>
internal static class DoctorCommand
{
    // String enums so the JSON is self-describing for the Desktop surface (#94).
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    /// <summary>
    /// Runs the doctor for the given sub-args. Returns 0 when ready, 1 when not
    /// ready, and 2 for a usage error (unknown target).
    /// </summary>
    public static async Task<int> RunAsync(
        ISpeakerLabelingDoctor doctor,
        string[] args,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(doctor);
        ArgumentNullException.ThrowIfNull(args);

        if (args.Length == 0 || !string.Equals(args[0], "speakers", StringComparison.OrdinalIgnoreCase))
        {
            CliOutput.WriteErrorLine("Usage: voxflow doctor speakers [--json]");
            return 2;
        }

        var asJson = args.Skip(1).Any(a => string.Equals(a, "--json", StringComparison.Ordinal));

        var report = await doctor.CheckAsync(cancellationToken).ConfigureAwait(false);
        CliOutput.WriteLine(asJson ? RenderJson(report) : RenderText(report));
        return report.IsReady ? 0 : 1;
    }

    public static string RenderText(SpeakerLabelingHealthReport report)
    {
        ArgumentNullException.ThrowIfNull(report);

        var sb = new StringBuilder();
        sb.AppendLine($"Speaker labeling: {(report.IsReady ? "ready" : "not ready")}");
        sb.AppendLine();

        foreach (var check in report.Checks)
        {
            sb.AppendLine($"{Label(check.Status),-6} {check.Name}: {check.Detail}");
        }

        if (!string.IsNullOrWhiteSpace(report.NextAction))
        {
            sb.AppendLine();
            sb.AppendLine("Next action:");
            sb.AppendLine($"  {report.NextAction}");
        }

        return sb.ToString().TrimEnd();
    }

    public static string RenderJson(SpeakerLabelingHealthReport report)
    {
        ArgumentNullException.ThrowIfNull(report);
        return JsonSerializer.Serialize(report, JsonOptions);
    }

    private static string Label(HealthCheckStatus status) => status switch
    {
        HealthCheckStatus.Ok => "OK",
        HealthCheckStatus.Fail => "FAIL",
        HealthCheckStatus.Skip => "SKIP",
        _ => "?",
    };
}
