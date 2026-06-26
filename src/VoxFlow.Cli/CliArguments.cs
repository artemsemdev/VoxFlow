using System;

namespace VoxFlow.Cli;

internal sealed record CliArguments(bool? EnableSpeakers, bool ShowHelp)
{
    public const string HelpText = """
        Usage: voxflow [command] [options]

        Commands:
          transcribe   Transcribe audio (the default when no command is given).
          doctor       Check speaker-labeling readiness. [coming soon]
          setup        Install or repair the speaker-labeling runtime. [coming soon]

        transcribe options:
          --speakers[=true|false]   Enable (or disable) speaker labeling for this
                                    run. Overrides transcription.speakerLabeling.enabled
                                    in appsettings.json.
          --no-speakers             Equivalent to --speakers=false.
          --help                    Print this message and exit.

        All other runtime settings come from appsettings.json.
        """;

    public static CliArguments Parse(string[] args)
    {
        bool? enableSpeakers = null;
        var showHelp = false;

        foreach (var raw in args)
        {
            if (raw == "--help")
            {
                showHelp = true;
                continue;
            }

            if (raw == "--no-speakers")
            {
                enableSpeakers = false;
                continue;
            }

            if (raw == "--speakers")
            {
                enableSpeakers = true;
                continue;
            }

            if (raw.StartsWith("--speakers=", StringComparison.Ordinal))
            {
                var value = raw["--speakers=".Length..];
                enableSpeakers = ParseBoolOrThrow(value, raw);
                continue;
            }

            throw new ArgumentException(
                $"Unknown command-line flag: {raw}. Use --help to see supported flags.");
        }

        return new CliArguments(enableSpeakers, showHelp);
    }

    private static bool ParseBoolOrThrow(string value, string sourceFlag)
    {
        if (string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(value, "false", StringComparison.OrdinalIgnoreCase)) return false;

        throw new ArgumentException(
            $"Invalid value for {sourceFlag}. Expected 'true' or 'false' (case-insensitive).");
    }
}
