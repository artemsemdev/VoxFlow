namespace VoxFlow.Desktop.Services;

internal sealed record DesktopCliInvocation(
    string WorkingDirectory,
    string? AssemblyPath,
    string? ProjectPath);
