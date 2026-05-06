using System;
using System.IO;

internal static class TestProjectPaths
{
    // Resolve once and cache it because every end-to-end test needs the same root path.
    private static readonly Lazy<string> RepositoryRootPath = new(FindRepositoryRoot);

    public static string RepositoryRoot => RepositoryRootPath.Value;

    // Default app project path used by the legacy TestProcessRunner.RunAppAsync path.
    // The CLI is the canonical app entry point in this repo.
    public static string AppProjectPath => Path.Combine(RepositoryRoot, "src", "VoxFlow.Cli", "VoxFlow.Cli.csproj");

    private static string FindRepositoryRoot()
    {
        var currentDirectory = new DirectoryInfo(AppContext.BaseDirectory);

        while (currentDirectory is not null)
        {
            // Walk upward from the test output directory until VoxFlow.sln is found.
            // (The legacy version of this helper looked for VoxFlow.csproj at the root,
            //  which has not existed since the project moved to a multi-project solution.)
            var candidateSolutionPath = Path.Combine(currentDirectory.FullName, "VoxFlow.sln");
            if (File.Exists(candidateSolutionPath))
            {
                return currentDirectory.FullName;
            }

            currentDirectory = currentDirectory.Parent;
        }

        throw new InvalidOperationException("Could not locate the repository root for tests (no VoxFlow.sln found above the test output directory).");
    }
}
