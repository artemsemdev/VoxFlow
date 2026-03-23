using System;
using System.IO;

internal static class TestProjectPaths
{
    // Resolve once and cache it because every end-to-end test needs the same root path.
    private static readonly Lazy<string> RepositoryRootPath = new(FindRepositoryRoot);

    public static string RepositoryRoot => RepositoryRootPath.Value;

    public static string AppProjectPath => Path.Combine(RepositoryRoot, "VoxFlow.csproj");

    private static string FindRepositoryRoot()
    {
        var currentDirectory = new DirectoryInfo(AppContext.BaseDirectory);

        while (currentDirectory is not null)
        {
            // Walk upward from the test output directory until the app project is found.
            var candidateProjectPath = Path.Combine(currentDirectory.FullName, "VoxFlow.csproj");
            if (File.Exists(candidateProjectPath))
            {
                return currentDirectory.FullName;
            }

            currentDirectory = currentDirectory.Parent;
        }

        throw new InvalidOperationException("Could not locate the repository root for tests.");
    }
}
