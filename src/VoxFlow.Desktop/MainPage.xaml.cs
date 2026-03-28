using Foundation;
using Microsoft.Maui.Controls;
using VoxFlow.Desktop.Services;
using VoxFlow.Desktop.ViewModels;

#if MACCATALYST
using System.Runtime.InteropServices;
using UIKit;
#endif
#if DEBUG && MACCATALYST
using VoxFlow.Desktop.Automation;
#endif

namespace VoxFlow.Desktop;

public partial class MainPage : ContentPage
{
    private readonly AppViewModel _viewModel;
#if DEBUG && MACCATALYST
    private DesktopUiAutomationHost? _uiAutomationHost;
#endif

    public MainPage(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        TryEnableOptionalPlatformFeatures();
    }

    private void TryEnableOptionalPlatformFeatures()
    {
#if DEBUG && MACCATALYST
        try
        {
            _uiAutomationHost = DesktopUiAutomationHost.TryStart(blazorWebView);
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("MainPage.DesktopUiAutomationHost", ex);
        }
#endif

        TryConfigureNativeDragAndDrop();
    }

    private void TryConfigureNativeDragAndDrop()
    {
#if MACCATALYST
        if (RuntimeInformation.ProcessArchitecture == Architecture.X64)
        {
            DesktopDiagnostics.LogInfo(
                "Skipping native drag and drop registration on Intel Mac Catalyst. Browse Files remains available.");
            return;
        }
#endif

        try
        {
            var dropGestureRecognizer = new DropGestureRecognizer
            {
                AllowDrop = true
            };

            dropGestureRecognizer.DragOver += HandleNativeDragOver;
            dropGestureRecognizer.Drop += HandleNativeDrop;
            blazorWebView.GestureRecognizers.Add(dropGestureRecognizer);
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("MainPage.TryConfigureNativeDragAndDrop", ex);
        }
    }

    private static void HandleNativeDragOver(object? sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    private async void HandleNativeDrop(object? sender, DropEventArgs e)
    {
        if (!_viewModel.CanStart)
        {
            DesktopDiagnostics.LogInfo("Native drop ignored: CanStart is false.");
            return;
        }

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
