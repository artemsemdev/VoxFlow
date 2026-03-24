using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace VoxFlow.Desktop.Services;

internal static partial class DesktopCliSupport
{
    public static bool ShouldUseCliBridge()
        => OperatingSystem.IsMacCatalyst()
            && RuntimeInformation.ProcessArchitecture == Architecture.X64;

    public static string FindRepositoryRoot(string baseDirectory)
    {
        var currentDirectory = new DirectoryInfo(baseDirectory);

        while (currentDirectory is not null)
        {
            if (File.Exists(Path.Combine(currentDirectory.FullName, "VoxFlow.sln")))
            {
                return currentDirectory.FullName;
            }

            currentDirectory = currentDirectory.Parent;
        }

        throw new InvalidOperationException(
            $"Could not locate VoxFlow.sln while searching upward from {baseDirectory}.");
    }

    public static string ResolveCliProjectPath(string repositoryRoot)
        => Path.Combine(repositoryRoot, "src", "VoxFlow.Cli", "VoxFlow.Cli.csproj");

    public static string? ResolveBuiltCliAssemblyPath(string repositoryRoot)
    {
        var candidates = new[]
        {
            Path.Combine(repositoryRoot, "src", "VoxFlow.Cli", "bin", "Debug", "net9.0", "VoxFlow.Cli.dll"),
            Path.Combine(repositoryRoot, "src", "VoxFlow.Cli", "bin", "Release", "net9.0", "VoxFlow.Cli.dll")
        };

        return candidates.FirstOrDefault(File.Exists);
    }

    public static string ExtractFailureMessage(string output)
    {
        var lines = output
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => !line.StartsWith("Build succeeded.", StringComparison.OrdinalIgnoreCase))
            .ToArray();

        var processingFailed = lines
            .LastOrDefault(line => line.StartsWith("Processing failed:", StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(processingFailed))
        {
            return processingFailed["Processing failed:".Length..].Trim();
        }

        var failChecks = lines
            .Where(line => line.Contains("[FAIL]", StringComparison.OrdinalIgnoreCase))
            .Select(line => line[(line.IndexOf("[FAIL]", StringComparison.OrdinalIgnoreCase) + "[FAIL]".Length)..].Trim())
            .ToArray();
        if (failChecks.Length > 0)
        {
            return string.Join("; ", failChecks);
        }

        var transcriptionFailed = lines
            .LastOrDefault(line => line.StartsWith("Transcription failed.", StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(transcriptionFailed))
        {
            return transcriptionFailed;
        }

        var startupFailed = lines
            .LastOrDefault(line => line.Contains("Transcription will not start", StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(startupFailed))
        {
            return startupFailed;
        }

        return lines.LastOrDefault(line => !string.IsNullOrWhiteSpace(line))
            ?? "CLI transcription failed.";
    }

    public static CliSuccessMetadata ExtractSuccessMetadata(string output)
    {
        var match = SuccessLineRegex().Match(output);
        if (!match.Success)
        {
            return new CliSuccessMetadata(null, 0);
        }

        var language = match.Groups["language"].Value.Trim();
        _ = int.TryParse(match.Groups["segments"].Value, out var acceptedSegments);
        return new CliSuccessMetadata(
            string.IsNullOrWhiteSpace(language) ? null : language,
            acceptedSegments);
    }

    [GeneratedRegex(@"Done\.\s+Language:\s*(?<language>.+?),\s*Segments:\s*(?<segments>\d+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SuccessLineRegex();
}

internal sealed record CliSuccessMetadata(string? DetectedLanguage, int AcceptedSegmentCount);
