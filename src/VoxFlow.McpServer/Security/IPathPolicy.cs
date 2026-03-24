#nullable enable

namespace VoxFlow.McpServer.Security;

/// <summary>
/// Validates file paths against configured allowed roots.
/// </summary>
internal interface IPathPolicy
{
    /// <summary>
    /// Validates that a path is safe for reading input files.
    /// </summary>
    void ValidateInputPath(string path);

    /// <summary>
    /// Validates that a path is safe for writing output files.
    /// </summary>
    void ValidateOutputPath(string path);

    /// <summary>
    /// Returns true if the path is within allowed input roots.
    /// </summary>
    bool IsAllowedInputPath(string path);

    /// <summary>
    /// Returns true if the path is within allowed output roots.
    /// </summary>
    bool IsAllowedOutputPath(string path);
}
