using System;
using System.IO;

internal static class TestProjectPaths
{
    private static readonly Lazy<string> RepositoryRootPath = new(FindRepositoryRoot);

    public static string RepositoryRoot => RepositoryRootPath.Value;

    public static string AppProjectPath => Path.Combine(RepositoryRoot, "src", "VoxFlow.Cli", "VoxFlow.Cli.csproj");

    private static string FindRepositoryRoot()
    {
        var currentDirectory = new DirectoryInfo(AppContext.BaseDirectory);

        while (currentDirectory is not null)
        {
            var candidateProjectPath = Path.Combine(currentDirectory.FullName, "src", "VoxFlow.Cli", "VoxFlow.Cli.csproj");
            if (File.Exists(candidateProjectPath))
            {
                return currentDirectory.FullName;
            }

            currentDirectory = currentDirectory.Parent;
        }

        throw new InvalidOperationException("Could not locate the repository root for CLI tests.");
    }
}
