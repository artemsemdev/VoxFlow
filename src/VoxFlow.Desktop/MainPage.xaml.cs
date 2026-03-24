using Foundation;
using Microsoft.Maui.Controls;
using VoxFlow.Desktop.ViewModels;

#if MACCATALYST
using UIKit;
#endif

namespace VoxFlow.Desktop;

public partial class MainPage : ContentPage
{
    private readonly AppViewModel _viewModel;

    public MainPage(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;

        var dropGestureRecognizer = new DropGestureRecognizer
        {
            AllowDrop = true
        };

        dropGestureRecognizer.DragOver += HandleNativeDragOver;
        dropGestureRecognizer.Drop += HandleNativeDrop;
        blazorWebView.GestureRecognizers.Add(dropGestureRecognizer);
    }

    private static void HandleNativeDragOver(object? sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void HandleNativeDrop(object? sender, DropEventArgs e)
    {
        var filePath = await TryGetDroppedAudioFilePathAsync(e);
        if (string.IsNullOrWhiteSpace(filePath))
        {
            return;
        }

        e.Handled = true;
        await _viewModel.TranscribeFileAsync(filePath);
    }

    private static async Task<string?> TryGetDroppedAudioFilePathAsync(DropEventArgs e)
    {
#if MACCATALYST
        var session = e.PlatformArgs?.DropSession;
        if (session is null)
        {
            return null;
        }

        foreach (var item in session.Items)
        {
            var filePath = await TryLoadFilePathAsync(item.ItemProvider);
            if (!string.IsNullOrWhiteSpace(filePath) && IsSupportedAudioFile(filePath))
            {
                return filePath;
            }
        }
#endif

        return null;
    }

#if MACCATALYST
    private static async Task<string?> TryLoadFilePathAsync(NSItemProvider itemProvider)
    {
        foreach (var typeIdentifier in new[] { "public.file-url", "public.url", "public.item" })
        {
            if (!itemProvider.HasItemConformingTo(typeIdentifier))
            {
                continue;
            }

            var item = await LoadItemAsync(itemProvider, typeIdentifier);
            var filePath = ExtractLocalPath(item);
            if (!string.IsNullOrWhiteSpace(filePath))
            {
                return filePath;
            }
        }

        return null;
    }

    private static Task<NSObject?> LoadItemAsync(NSItemProvider itemProvider, string typeIdentifier)
    {
        var completionSource = new TaskCompletionSource<NSObject?>(TaskCreationOptions.RunContinuationsAsynchronously);

        itemProvider.LoadItem(typeIdentifier, null, (item, error) =>
        {
            if (error is not null)
            {
                completionSource.TrySetException(new NSErrorException(error));
                return;
            }

            completionSource.TrySetResult(item);
        });

        return completionSource.Task;
    }

    private static string? ExtractLocalPath(NSObject? item)
    {
        switch (item)
        {
            case NSUrl url when url.IsFileUrl:
                return url.Path;
            case NSString text:
                return ParseLocalPath(text.ToString());
            case NSData data:
                return ParseLocalPath(NSString.FromData(data, NSStringEncoding.UTF8)?.ToString());
            default:
                return null;
        }
    }
#endif

    private static string? ParseLocalPath(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.IsFile)
        {
            return uri.LocalPath;
        }

        return File.Exists(value) ? Path.GetFullPath(value) : null;
    }

    private static bool IsSupportedAudioFile(string filePath)
    {
        var extension = Path.GetExtension(filePath);
        return extension.Equals(".m4a", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".wav", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".mp3", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".aac", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".flac", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".ogg", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".aif", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".aiff", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".mp4", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".m4b", StringComparison.OrdinalIgnoreCase);
    }
}
