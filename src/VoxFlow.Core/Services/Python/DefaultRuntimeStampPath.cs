using System;
using System.IO;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Production location of the speaker-labeling runtime stamp. It sits beside the
/// managed venv root under the OS application-support directory
/// (<c>~/Library/Application Support/VoxFlow/speaker-labeling-runtime.json</c> on
/// macOS), not inside <c>python-runtime/</c>, so deleting the venv and deleting
/// the stamp remain independent operations.
/// </summary>
public static class DefaultRuntimeStampPath
{
    public static string FilePath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "VoxFlow",
        "speaker-labeling-runtime.json");
}
