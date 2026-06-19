namespace VoxFlow.Cli;

using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;

/// <summary>
/// Renders transcription progress as three sequential per-phase bars
/// (Transcription, Diarization, Merge), each with its own color and its
/// own 0-100 local percent. Overall <see cref="ProgressStage"/> events are
/// mapped into whichever phase they belong to, and phase transitions are
/// committed to their own line so the user sees a stacked history instead
/// of one bar smeared across unrelated workloads.
///
/// Owns a wall-clock heartbeat so the elapsed counter keeps moving between
/// producer events -- during pyannote diarization, hook events are sparse
/// (10-60s silences between sub-steps) and the bar would otherwise look
/// frozen.
/// </summary>
internal sealed class CliProgressHandler : IProgress<ProgressUpdate>, IDisposable
{
    private const string StructuredProgressPrefix = "VOXFLOW_PROGRESS ";
    private const int PhaseLabelWidth = 13;
    private static readonly TimeSpan DefaultHeartbeatInterval = TimeSpan.FromSeconds(1);

    private readonly ConsoleProgressOptions _options;
    private readonly TimeSpan _heartbeatInterval;
    private readonly bool _useAnsi;
    private readonly Stopwatch _throttle = Stopwatch.StartNew();
    private readonly object _stateLock = new();
    private long _lastRenderTick;
    private Timer? _heartbeat;
    private ProgressUpdate? _lastUpdate;
    private DateTime _lastUpdateUtc;
    private ProgressPhase? _lastPhase;

    private static ProgressPhase PhaseOf(ProgressStage stage) => ProgressPhaseBanding.PhaseOf(stage);
    private static double LocalPercent(ProgressStage stage, double overall) => ProgressPhaseBanding.LocalPercent(stage, overall);
    private static double PhaseUpperBound(ProgressStage stage) => ProgressPhaseBanding.PhaseUpperBound(stage);

    public CliProgressHandler(ConsoleProgressOptions options)
        : this(options, DefaultHeartbeatInterval)
    {
    }

    internal CliProgressHandler(ConsoleProgressOptions options, TimeSpan heartbeatInterval)
    {
        _options = options;
        _heartbeatInterval = heartbeatInterval;
        _useAnsi = options.UseColors && !Console.IsOutputRedirected;
    }

    public void Report(ProgressUpdate value)
    {
        if (string.Equals(Environment.GetEnvironmentVariable("VOXFLOW_PROGRESS_STREAM"), "1", StringComparison.Ordinal))
        {
            ReportStructured(value);
            return;
        }

        if (!_options.Enabled)
            return;

        ProgressUpdate? previousForFinalize = null;
        lock (_stateLock)
        {
            var newPhase = PhaseOf(value.Stage);
            var phaseChanged = _lastPhase.HasValue && _lastPhase.Value != newPhase;
            if (phaseChanged)
            {
                previousForFinalize = _lastUpdate;
            }
            _lastUpdate = value;
            _lastUpdateUtc = DateTime.UtcNow;
            _lastPhase = newPhase;

            var isTerminal = value.Stage is ProgressStage.Complete or ProgressStage.Failed;
            if (isTerminal)
            {
                DisposeHeartbeatLocked();
            }
            else
            {
                EnsureHeartbeatLocked();
            }
        }

        if (previousForFinalize is not null)
        {
            // Neither producer reliably emits a closing 100% frame: Whisper's
            // progress callback stops in the 75-90% range and pyannote's
            // ProgressHook emits step-boundary events without total/completed
            // for most sub-steps, leaving Fraction null. Synthesize a final
            // frame at the previous phase's band ceiling so the committed
            // stacked history shows each completed phase finished cleanly.
            var finalized = previousForFinalize with
            {
                PercentComplete = PhaseUpperBound(previousForFinalize.Stage),
                Message = "done"
            };
            RenderLine(finalized, isTerminal: false);
            CliOutput.WriteLine();
            _lastRenderTick = 0;
        }

        RenderThrottled(value);
    }

    private void RenderThrottled(ProgressUpdate value)
    {
        var isTerminal = value.Stage is ProgressStage.Complete or ProgressStage.Failed;
        if (!isTerminal)
        {
            var now = _throttle.ElapsedMilliseconds;
            if (now - _lastRenderTick < _options.RefreshIntervalMilliseconds)
                return;
            _lastRenderTick = now;
        }
        RenderLine(value, isTerminal);
    }

    private void RenderLine(ProgressUpdate value, bool isTerminal)
    {
        var output = new StringBuilder();

        if (value.BatchFileIndex.HasValue && value.BatchFileTotal.HasValue)
        {
            output.Append(Colorize($"[File {value.BatchFileIndex}/{value.BatchFileTotal}] ", "36"));
        }

        var phaseLabel = FormatPhase(value.Stage);
        output.Append(Colorize(phaseLabel, PhaseColor(value.Stage)));

        output.Append(' ');
        var localPercent = LocalPercent(value.Stage, value.PercentComplete);
        AppendProgressBar(output, localPercent);

        output.Append(Colorize(string.Format(CultureInfo.InvariantCulture, " {0,5:F1}%", localPercent), "97"));
        output.Append(Colorize($"  {FormatElapsed(value.Elapsed)}", "90"));

        if (!string.IsNullOrEmpty(value.CurrentLanguage))
        {
            output.Append(Colorize($"  [{value.CurrentLanguage}]", "33"));
        }

        var subStatus = FormatSubStatus(value);
        if (!string.IsNullOrEmpty(subStatus))
        {
            output.Append(Colorize($"  {subStatus}", "90"));
        }

        var padded = output.ToString().PadRight(CliOutput.IsOutputRedirected ? 0 : CliOutput.WindowWidth - 1);

        if (isTerminal)
        {
            CliOutput.Write($"\r{padded}");
            CliOutput.WriteLine();
        }
        else
        {
            CliOutput.Write($"\r{padded}");
        }
    }

    private void EnsureHeartbeatLocked()
    {
        if (_heartbeat is not null) return;
        _heartbeat = new Timer(OnHeartbeat, state: null, _heartbeatInterval, _heartbeatInterval);
    }

    private void DisposeHeartbeatLocked()
    {
        _heartbeat?.Dispose();
        _heartbeat = null;
    }

    private void OnHeartbeat(object? _)
    {
        ProgressUpdate projected;
        lock (_stateLock)
        {
            if (_lastUpdate is null) return;
            var isTerminal = _lastUpdate.Stage is ProgressStage.Complete or ProgressStage.Failed;
            if (isTerminal) return;

            var delta = DateTime.UtcNow - _lastUpdateUtc;
            if (delta < TimeSpan.Zero) delta = TimeSpan.Zero;
            projected = _lastUpdate with { Elapsed = _lastUpdate.Elapsed + delta };
        }
        // Heartbeat deliberately bypasses the throttle -- we *want* to refresh
        // the displayed clock on every tick even if a real Report just ran.
        try
        {
            RenderLine(projected, isTerminal: false);
        }
        catch
        {
            // Console writes can throw if stdout was closed mid-run (test
            // teardown, redirected stream disposed). Never surface from a
            // heartbeat callback -- progress is best-effort.
        }
    }

    private void AppendProgressBar(StringBuilder sb, double percent)
    {
        var width = _options.ProgressBarWidth;
        var filled = (int)(percent / 100.0 * width);
        if (filled > width) filled = width;
        if (filled < 0) filled = 0;

        sb.Append(Colorize("[", "90"));

        if (filled > 0)
            sb.Append(Colorize(new string('█', filled), "92"));

        var remaining = width - filled;
        if (remaining > 0)
            sb.Append(Colorize(new string('░', remaining), "90"));

        sb.Append(Colorize("]", "90"));
    }

    private static string FormatPhase(ProgressStage stage)
    {
        if (stage == ProgressStage.Failed)
            return "Failed".PadRight(PhaseLabelWidth);

        var label = PhaseOf(stage) switch
        {
            ProgressPhase.Transcription => "Transcription",
            ProgressPhase.Diarization => "Diarization",
            ProgressPhase.Merge => "Merge",
            _ => "Working"
        };
        return label.PadRight(PhaseLabelWidth);
    }

    private static string PhaseColor(ProgressStage stage)
    {
        if (stage == ProgressStage.Failed) return "91";
        return PhaseOf(stage) switch
        {
            ProgressPhase.Transcription => "96",
            ProgressPhase.Diarization => "95",
            ProgressPhase.Merge => "92",
            _ => "94"
        };
    }

    private static string? FormatSubStatus(ProgressUpdate value)
    {
        // Prefer an explicit producer message; otherwise fall back to the
        // raw stage name so the user always sees which sub-step we're on
        // inside the current phase (e.g. "loading model" under Transcription
        // or "embeddings" under Diarization).
        if (!string.IsNullOrEmpty(value.Message))
            return value.Message;
        return StageSubLabel(value.Stage);
    }

    private static string? StageSubLabel(ProgressStage stage) => stage switch
    {
        ProgressStage.Validating => "validating",
        ProgressStage.Converting => "converting audio",
        ProgressStage.LoadingModel => "loading model",
        ProgressStage.Transcribing => "transcribing",
        ProgressStage.Filtering => "filtering segments",
        ProgressStage.Diarizing => "diarizing",
        ProgressStage.Writing => "writing output",
        ProgressStage.Complete => "done",
        ProgressStage.Failed => "failed",
        _ => null
    };

    private static string FormatElapsed(TimeSpan elapsed)
    {
        return elapsed.TotalHours >= 1
            ? elapsed.ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture)
            : elapsed.ToString(@"m\:ss", CultureInfo.InvariantCulture);
    }

    private string Colorize(string text, string colorCode)
    {
        if (!_useAnsi || string.IsNullOrEmpty(text))
            return text;

        return $"\u001b[{colorCode}m{text}\u001b[0m";
    }

    private static void ReportStructured(ProgressUpdate value)
    {
        var payload = JsonSerializer.Serialize(new CliProgressEnvelope(
            value.Stage.ToString(),
            value.PercentComplete,
            (long)value.Elapsed.TotalMilliseconds,
            value.Message,
            value.CurrentLanguage,
            value.BatchFileIndex,
            value.BatchFileTotal));

        CliOutput.WriteErrorLine($"{StructuredProgressPrefix}{payload}");
    }

    public void Dispose()
    {
        lock (_stateLock)
        {
            DisposeHeartbeatLocked();
        }
    }
}

internal sealed record CliProgressEnvelope(
    string Stage,
    double PercentComplete,
    long ElapsedMilliseconds,
    string? Message,
    string? CurrentLanguage,
    int? BatchFileIndex,
    int? BatchFileTotal);
