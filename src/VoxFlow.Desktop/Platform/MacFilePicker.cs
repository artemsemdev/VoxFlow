namespace VoxFlow.Desktop.Platform;

public static class MacFilePicker
{
    private static readonly FilePickerFileType AudioFileTypes = new(
        new Dictionary<DevicePlatform, IEnumerable<string>>
        {
            { DevicePlatform.macOS, new[] { "public.audio" } },
            { DevicePlatform.MacCatalyst, new[] { "public.audio" } }
        });

    public static async Task<string?> PickAudioFileAsync()
    {
        var result = await FilePicker.Default.PickAsync(new PickOptions
        {
            PickerTitle = "Select audio file to transcribe",
            FileTypes = AudioFileTypes
        });

        return result?.FullPath;
    }
}
