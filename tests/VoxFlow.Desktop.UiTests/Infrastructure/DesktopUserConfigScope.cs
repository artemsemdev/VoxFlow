using System.Text.Json;
using System.Text.Json.Nodes;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class DesktopUserConfigScope : IAsyncDisposable
{
    private readonly string _configPath;
    private readonly string? _originalContent;
    private readonly bool _hadOriginalFile;

    public DesktopUserConfigScope()
    {
        _configPath = RepositoryLayout.DesktopUserConfigPath;
        _hadOriginalFile = File.Exists(_configPath);
        _originalContent = _hadOriginalFile ? File.ReadAllText(_configPath) : null;

        var directory = Path.GetDirectoryName(_configPath)
            ?? throw new InvalidOperationException("Desktop user config path does not have a parent directory.");
        Directory.CreateDirectory(directory);
    }

    public async Task WriteAsync(JsonObject root)
    {
        await File.WriteAllTextAsync(
            _configPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    public ValueTask DisposeAsync()
    {
        if (_hadOriginalFile)
        {
            File.WriteAllText(_configPath, _originalContent ?? string.Empty);
        }
        else if (File.Exists(_configPath))
        {
            File.Delete(_configPath);
        }

        return ValueTask.CompletedTask;
    }
}
