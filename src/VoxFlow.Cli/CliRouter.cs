using System;
using System.Collections.Generic;
using System.Linq;

namespace VoxFlow.Cli;

/// <summary>The top-level CLI commands.</summary>
internal enum CliVerb
{
    Transcribe,
    Doctor,
    Setup,
}

/// <summary>A routed command: the selected <see cref="Verb"/> and the arguments
/// that belong to it (with the verb token, if any, stripped).</summary>
internal sealed record CliRoute(CliVerb Verb, string[] Args);

/// <summary>
/// Maps <c>args</c> to a <see cref="CliRoute"/>. Verbs are explicit
/// (<c>transcribe</c> / <c>doctor</c> / <c>setup</c>); anything else — no args, or
/// a leading flag like <c>--speakers</c> — defaults to <see cref="CliVerb.Transcribe"/>
/// so existing flag-only invocations keep working. An unrecognized leading token
/// is a usage error.
/// </summary>
internal static class CliRouter
{
    private static readonly IReadOnlyDictionary<string, CliVerb> VerbsByName =
        new Dictionary<string, CliVerb>(StringComparer.OrdinalIgnoreCase)
        {
            ["transcribe"] = CliVerb.Transcribe,
            ["doctor"] = CliVerb.Doctor,
            ["setup"] = CliVerb.Setup,
        };

    /// <summary>The verb names, in display order, for help and error messages.</summary>
    public static IReadOnlyList<string> VerbNames { get; } = new[] { "transcribe", "doctor", "setup" };

    public static CliRoute Route(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);

        // No args, or a leading flag, means the default verb (transcribe) with the
        // original args — this preserves `voxflow`, `voxflow --speakers`, `voxflow --help`.
        if (args.Length == 0 || args[0].StartsWith('-'))
        {
            return new CliRoute(CliVerb.Transcribe, args);
        }

        if (VerbsByName.TryGetValue(args[0], out var verb))
        {
            return new CliRoute(verb, args.Skip(1).ToArray());
        }

        throw new ArgumentException(
            $"Unknown command: {args[0]}. Available commands: {string.Join(", ", VerbNames)}. Use --help.");
    }
}
