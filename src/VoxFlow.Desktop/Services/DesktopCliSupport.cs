using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxFlow.Core.Models;

namespace VoxFlow.Desktop.Services;

internal static partial class DesktopCliSupport
{
    private const string StructuredProgressPrefix = "VOXFLOW_PROGRESS ";

    public static bool ShouldUseCliBridge()
        => OperatingSystem.IsMacCatalyst()
            && RuntimeInformation.ProcessArchitecture == Architecture.X64;

    public static DesktopCliInvocation ResolveCliInvocation(string baseDirectory)
    {
        var bundledAssemblyPath = ResolveBundledCliAssemblyPath(baseDirectory);
        if (!string.IsNullOrWhiteSpace(bundledAssemblyPath))
        {
            return new DesktopCliInvocation(
                Path.GetDirectoryName(bundledAssemblyPath)!,
                bundledAssemblyPath,
                null);
        }

        var repositoryRoot = FindRepositoryRoot(baseDirectory);
        var builtCliAssembly = ResolveBuiltCliAssemblyPath(repositoryRoot);
        if (!string.IsNullOrWhiteSpace(builtCliAssembly))
        {
            return new DesktopCliInvocation(repositoryRoot, builtCliAssembly, null);
        }

        return new DesktopCliInvocation(
            repositoryRoot,
            null,
            ResolveCliProjectPath(repositoryRoot));
    }

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

    public static string? ResolveBundledCliAssemblyPath(string baseDirectory)
    {
        var candidates = new[]
        {
            Path.Combine(baseDirectory, "cli", "VoxFlow.Cli.dll"),
            Path.GetFullPath(Path.Combine(baseDirectory, "..", "MonoBundle", "cli", "VoxFlow.Cli.dll")),
            Path.GetFullPath(Path.Combine(baseDirectory, "..", "..", "MonoBundle", "cli", "VoxFlow.Cli.dll"))
        };

        return candidates.FirstOrDefault(File.Exists);
    }

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

    public static bool TryParseProgressUpdate(string line, [NotNullWhen(true)] out ProgressUpdate? progressUpdate)
    {
        progressUpdate = null;

        if (!line.StartsWith(StructuredProgressPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        var payload = line[StructuredProgressPrefix.Length..].Trim();
        if (string.IsNullOrWhiteSpace(payload))
        {
            return false;
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<CliProgressEnvelope>(payload);
            if (envelope is null ||
                !Enum.TryParse<ProgressStage>(envelope.Stage, ignoreCase: true, out var stage))
            {
                return false;
            }

            progressUpdate = new ProgressUpdate(
                stage,
                envelope.PercentComplete,
                TimeSpan.FromMilliseconds(Math.Max(0, envelope.ElapsedMilliseconds)),
                envelope.Message,
                envelope.CurrentLanguage,
                envelope.BatchFileIndex,
                envelope.BatchFileTotal);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    [GeneratedRegex(@"Done\.\s+Language:\s*(?<language>.+?),\s*Segments:\s*(?<segments>\d+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex SuccessLineRegex();
}

internal sealed record CliProgressEnvelope(
    string Stage,
    double PercentComplete,
    long ElapsedMilliseconds,
    string? Message,
    string? CurrentLanguage,
    int? BatchFileIndex,
    int? BatchFileTotal);

internal sealed record CliSuccessMetadata(string? DetectedLanguage, int AcceptedSegmentCount);
