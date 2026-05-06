using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using NJsonSchema;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <summary>
/// Default <see cref="IDiarizationSidecar"/> that invokes
/// <c>voxflow_diarize.py</c> via the configured <see cref="IPythonRuntime"/>
/// and <see cref="IProcessLauncher"/>. Owns: writing the JSON request on
/// stdin, parsing stdout per sidecar-diarization-v1, mapping failures to
/// <see cref="DiarizationSidecarException"/>.
/// </summary>
public sealed class PyannoteSidecarClient : IDiarizationSidecar
{
    private const int ProtocolVersion = 1;
    private const string SchemaResourceName = "VoxFlow.Core.Contracts.sidecar-diarization-v1.schema.json";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    // Async lazy: NJsonSchema 11 only exposes JsonSchema.FromJsonAsync, so the
    // previous Lazy<JsonSchema> factory had to call .GetAwaiter().GetResult().
    // Lazy<Task<JsonSchema>> caches the in-flight Task so concurrent callers
    // share a single load, and DiarizeAsync awaits it on its own async stack.
    private static readonly Lazy<Task<JsonSchema>> ResponseSchema = new(LoadResponseSchemaAsync);

    private static Task<JsonSchema> LoadResponseSchemaAsync()
    {
        using var stream = typeof(PyannoteSidecarClient).Assembly
            .GetManifestResourceStream(SchemaResourceName)
            ?? throw new InvalidOperationException(
                $"Embedded schema '{SchemaResourceName}' not found.");
        using var reader = new StreamReader(stream);
        var schemaText = reader.ReadToEnd();
        return JsonSchema.FromJsonAsync(schemaText);
    }

    private readonly IPythonRuntime _runtime;
    private readonly IProcessLauncher _launcher;
    private readonly string _scriptPath;
    private readonly TimeSpan _timeout;

    public PyannoteSidecarClient(
        IPythonRuntime runtime,
        IProcessLauncher launcher,
        string scriptPath,
        TimeSpan timeout)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentNullException.ThrowIfNull(launcher);
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptPath);
        _runtime = runtime;
        _launcher = launcher;
        _scriptPath = scriptPath;
        _timeout = timeout;
    }

    public async Task<DiarizationResult> DiarizeAsync(
        DiarizationRequest request,
        IProgress<SpeakerLabelingProgress>? progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var status = await _runtime.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!status.IsReady)
        {
            throw new DiarizationSidecarException(
                SidecarFailureReason.RuntimeNotReady,
                $"Python runtime is not ready: {status.Error}");
        }

        var psi = _runtime.CreateStartInfo(_scriptPath, Array.Empty<string>());
        var payload = JsonSerializer.Serialize(
            new RequestEnvelope(ProtocolVersion, request.WavPath),
            SerializerOptions);

        using var timeoutCts = new CancellationTokenSource(_timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, timeoutCts.Token);

        ProcessExecutionResult process;
        try
        {
            // Stream stderr per-line so the .NET side can animate the CLI bar
            // as pyannote emits ProgressHook events. Buffering via ReadToEnd
            // would pin the bar until process exit -- the exact "frozen bar"
            // UX bug we are fixing.
            process = await _launcher.RunAsync(
                psi,
                payload,
                onStdErrLine: line => ReportProgressLine(line, progress),
                linkedCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new DiarizationSidecarException(
                    SidecarFailureReason.Timeout,
                    $"voxflow_diarize.py did not return within {_timeout.TotalSeconds:0.##}s");
            }
            throw;
        }

        if (process.ExitCode != 0 && string.IsNullOrWhiteSpace(process.StdOut))
        {
            throw new DiarizationSidecarException(
                SidecarFailureReason.ProcessCrashed,
                $"voxflow_diarize.py exited with code {process.ExitCode}. stderr: {process.StdErr}");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(process.StdOut);
        }
        catch (JsonException ex)
        {
            throw new DiarizationSidecarException(
                SidecarFailureReason.MalformedJson,
                $"voxflow_diarize.py wrote non-JSON to stdout: {ex.Message}",
                ex);
        }

        using (document)
        {
            var root = document.RootElement;

            // Error envelopes are valid against the schema but short-circuit here
            // so we return a useful message instead of a structural complaint.
            if (root.TryGetProperty("status", out var statusElement)
                && string.Equals(statusElement.GetString(), "error", StringComparison.Ordinal))
            {
                var message = root.TryGetProperty("error", out var errorElement)
                    ? errorElement.GetString() ?? "unknown error"
                    : "unknown error";
                throw new DiarizationSidecarException(
                    SidecarFailureReason.ErrorResponseReturned,
                    $"voxflow_diarize.py returned error envelope: {message}");
            }

            var schema = await ResponseSchema.Value.ConfigureAwait(false);
            var validationErrors = schema.Validate(process.StdOut);
            if (validationErrors.Count > 0)
            {
                var joined = string.Join("; ", validationErrors.Select(e => e.ToString()));
                throw new DiarizationSidecarException(
                    SidecarFailureReason.SchemaViolation,
                    $"voxflow_diarize.py response failed schema validation: {joined}");
            }

            return ParseResponse(root);
        }
    }

    private static DiarizationResult ParseResponse(JsonElement root)
    {
        var version = root.GetProperty("version").GetInt32();
        var speakers = new List<DiarizationSpeaker>();
        foreach (var el in root.GetProperty("speakers").EnumerateArray())
        {
            speakers.Add(new DiarizationSpeaker(
                el.GetProperty("id").GetString() ?? string.Empty,
                el.GetProperty("totalDuration").GetDouble()));
        }

        var segments = new List<DiarizationSegment>();
        foreach (var el in root.GetProperty("segments").EnumerateArray())
        {
            segments.Add(new DiarizationSegment(
                el.GetProperty("speaker").GetString() ?? string.Empty,
                el.GetProperty("start").GetDouble(),
                el.GetProperty("end").GetDouble()));
        }

        return new DiarizationResult(version, speakers, segments);
    }

    private static void ReportProgressLine(string rawLine, IProgress<SpeakerLabelingProgress>? progress)
    {
        if (progress is null)
        {
            return;
        }

        var line = rawLine.Trim();
        if (line.Length == 0 || line[0] != '{')
        {
            return;
        }

        SpeakerLabelingProgress? parsed;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("stage", out var stageEl))
            {
                return;
            }
            var stage = stageEl.GetString();
            if (stage is null)
            {
                return;
            }
            double? fraction = root.TryGetProperty("fraction", out var fracEl)
                && fracEl.ValueKind == JsonValueKind.Number
                    ? fracEl.GetDouble()
                    : null;
            parsed = new SpeakerLabelingProgress(stage, fraction);
        }
        catch (JsonException)
        {
            parsed = null;
        }

        if (parsed is not null)
        {
            progress.Report(parsed);
        }
    }

    private sealed record RequestEnvelope(
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("wavPath")] string WavPath);
}
