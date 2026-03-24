namespace VoxFlow.Desktop.Platform;

public static class MacFilePicker
{
    private static readonly FilePickerFileType AudioFileTypes = new(
        new Dictionary<DevicePlatform, IEnumerable<string>>
        {
            { DevicePlatform.macOS, new[] { "public.audio" } },
            { DevicePlatform.MacCatalyst, new[] { "public.audio" } }
        });

    private static readonly PickOptions AudioPickOptions = new()
    {
        PickerTitle = "Select audio file to transcribe",
        FileTypes = AudioFileTypes
    };

    public static async Task<string?> PickAudioFileAsync()
    {
        return await MainThread.InvokeOnMainThreadAsync(async () =>
        {
            var result = await FilePicker.Default.PickAsync(AudioPickOptions);
            return result?.FullPath;
        });
    }
}
