namespace VoxFlow.Desktop.Platform
{
    public static class MacFilePicker
    {
        public static Func<Task<string?>> PickAudioFileAsyncHandler { get; set; }
            = static () => Task.FromResult<string?>(null);

        public static Task<string?> PickAudioFileAsync() => PickAudioFileAsyncHandler();

        public static void Reset()
        {
            PickAudioFileAsyncHandler = static () => Task.FromResult<string?>(null);
        }
    }
}

public sealed record DevicePlatform(string Name)
{
    public static DevicePlatform macOS { get; } = new("macOS");
    public static DevicePlatform MacCatalyst { get; } = new("MacCatalyst");
}

public sealed class FilePickerFileType
{
    public FilePickerFileType(IDictionary<DevicePlatform, IEnumerable<string>> value)
    {
        Value = value;
    }

    public IDictionary<DevicePlatform, IEnumerable<string>> Value { get; }
}

public sealed class PickOptions
{
    public string? PickerTitle { get; set; }
    public FilePickerFileType? FileTypes { get; set; }
}

public sealed class FileResult
{
    public string? FullPath { get; init; }
}

public sealed class FilePicker
{
    public static FilePicker Default { get; set; } = new();

    public Func<PickOptions?, Task<FileResult?>> PickAsyncHandler { get; set; }
        = static _ => Task.FromResult<FileResult?>(null);

    public Task<FileResult?> PickAsync(PickOptions options)
    {
        return PickAsyncHandler(options);
    }
}

public sealed class ReadOnlyFile
{
    public ReadOnlyFile(string fullPath)
    {
        FullPath = fullPath;
    }

    public string FullPath { get; }
}

public sealed class OpenFileRequest
{
    public ReadOnlyFile? File { get; init; }
}

public sealed class Launcher
{
    public static Launcher Default { get; set; } = new();

    public List<object> OpenedTargets { get; } = [];

    public Task OpenAsync(string path)
    {
        OpenedTargets.Add(path);
        return Task.CompletedTask;
    }

    public Task OpenAsync(OpenFileRequest request)
    {
        OpenedTargets.Add(request);
        return Task.CompletedTask;
    }
}

public sealed class Clipboard
{
    public static Clipboard Default { get; set; } = new();

    public List<string> CopiedTexts { get; } = [];

    public Task SetTextAsync(string text)
    {
        CopiedTexts.Add(text);
        return Task.CompletedTask;
    }
}

public static class MainThread
{
    public static void BeginInvokeOnMainThread(Action callback)
    {
        callback();
    }

    public static Task<T> InvokeOnMainThreadAsync<T>(Func<Task<T>> callback)
    {
        return callback();
    }
}
