using Foundation;
using Microsoft.AspNetCore.Components.WebView;
using Microsoft.Maui.Controls;
using System.Linq;
using VoxFlow.Core.Configuration;
using VoxFlow.Desktop.Services;
using VoxFlow.Desktop.ViewModels;

#if MACCATALYST
using UIKit;
using WebKit;
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
#if MACCATALYST
    private readonly List<UIDropInteraction> _nativeDropInteractions = [];
    private readonly List<DropGestureRecognizer> _mauiDropGestureRecognizers = [];
    private NativeFileDropDelegate? _nativeFileDropDelegate;
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
            _uiAutomationHost = DesktopUiAutomationHost.TryStart(blazorWebView, _viewModel);
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
        TryAttachMauiDropRecognizer(rootLayout, "RootLayout");
        TryAttachMauiDropRecognizer(blazorWebView, "BlazorWebView");

#if MACCATALYST
        blazorWebView.BlazorWebViewInitialized += HandleBlazorWebViewInitialized;
        TryAttachNativeDropTargetFromHandler();
#else
#endif
    }

    private void TryAttachMauiDropRecognizer(View view, string viewName)
    {
        try
        {
            if (_mauiDropGestureRecognizers.Any(recognizer => view.GestureRecognizers.Contains(recognizer)))
            {
                return;
            }

            var dropGestureRecognizer = new DropGestureRecognizer
            {
                AllowDrop = true
            };

            dropGestureRecognizer.DragOver += HandleNativeDragOver;
            dropGestureRecognizer.Drop += HandleNativeDrop;
            view.GestureRecognizers.Add(dropGestureRecognizer);
            _mauiDropGestureRecognizers.Add(dropGestureRecognizer);
            DesktopDiagnostics.LogInfo($"MAUI drop recognizer attached to {viewName}.");
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException($"MainPage.TryAttachMauiDropRecognizer({viewName})", ex);
        }
    }

#if MACCATALYST
    private void HandleBlazorWebViewInitialized(object? sender, BlazorWebViewInitializedEventArgs e)
    {
        AttachNativeDropTarget(e.WebView);
    }

    private void TryAttachNativeDropTargetFromHandler()
    {
        if (blazorWebView.Handler?.PlatformView is WKWebView webView)
        {
            AttachNativeDropTarget(webView);
            return;
        }

        DesktopDiagnostics.LogInfo("Native drop target is waiting for WKWebView initialization.");
    }

    private void AttachNativeDropTarget(WKWebView webView)
    {
        try
        {
            _nativeFileDropDelegate ??= new NativeFileDropDelegate(this);
            AttachNativeDropTarget(webView, "WKWebView");
            AttachNativeDropTarget(webView.ScrollView, "WKWebView.ScrollView");
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("MainPage.AttachNativeDropTarget", ex);
        }
    }

    private void AttachNativeDropTarget(UIView view, string viewName)
    {
        if (_nativeDropInteractions.Any(interaction => ReferenceEquals(interaction.View, view)))
        {
            return;
        }

        var interaction = new UIDropInteraction(_nativeFileDropDelegate!);
        view.AddInteraction(interaction);
        _nativeDropInteractions.Add(interaction);
        DesktopDiagnostics.LogInfo($"Native file drop target attached to {viewName}.");
    }

    private async Task HandleNativeDropAsync(IUIDropSession session)
    {
        if (!_viewModel.CanStart)
        {
            DesktopDiagnostics.LogInfo("Native drop ignored: CanStart is false.");
            return;
        }

        DesktopDiagnostics.LogInfo("Native drop received.");
        var filePath = await TryGetDroppedAudioFilePathAsync(session);
        if (string.IsNullOrWhiteSpace(filePath))
        {
            DesktopDiagnostics.LogInfo("Native drop ignored: no supported local audio file path was resolved.");
            return;
        }

        DesktopDiagnostics.LogInfo($"Native drop accepted: {filePath}");
        await _viewModel.TranscribeFileAsync(filePath);
    }
#endif

    private static void HandleNativeDragOver(object? sender, DragEventArgs e)
    {
        DesktopDiagnostics.LogInfo("MAUI drop recognizer DragOver.");
        e.AcceptedOperation = DataPackageOperation.Copy;
    }

    // async void is reserved for UI event handlers like this one; the framework has no
    // Task to observe so any uncaught exception escapes to the synchronization context
    // and crashes the app. Wrap the body in a top-level try/catch that logs the failure
    // and shows the user a non-crashing error dialog. The inner work runs in
    // HandleNativeDropCoreAsync, which can be exercised independently of MAUI for tests
    // that need it.
    private async void HandleNativeDrop(object? sender, DropEventArgs e)
    {
        try
        {
            await HandleNativeDropCoreAsync(e);
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("MainPage.HandleNativeDrop", ex);
            try
            {
                await DisplayAlert(
                    "Drop failed",
                    $"VoxFlow could not handle the dropped file: {ex.Message}",
                    "OK");
            }
            catch (Exception alertEx)
            {
                // DisplayAlert can fail if the page is detached or the platform handler
                // is not yet attached — last-ditch logging keeps the failure visible.
                DesktopDiagnostics.LogException("MainPage.HandleNativeDrop.DisplayAlert", alertEx);
            }
        }
    }

    private async Task HandleNativeDropCoreAsync(DropEventArgs e)
    {
        DesktopDiagnostics.LogInfo("MAUI drop recognizer Drop invoked.");
        if (!_viewModel.CanStart)
        {
            DesktopDiagnostics.LogInfo("Native drop ignored: CanStart is false.");
            return;
        }

        var filePath = await TryGetDroppedAudioFilePathAsync(e);
        if (string.IsNullOrWhiteSpace(filePath))
        {
            DesktopDiagnostics.LogInfo("MAUI drop recognizer ignored drop: no supported local audio file path was resolved.");
            return;
        }

        e.Handled = true;
        DesktopDiagnostics.LogInfo($"MAUI drop recognizer accepted: {filePath}");
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
    private static async Task<string?> TryGetDroppedAudioFilePathAsync(IUIDropSession session)
    {
        foreach (var item in session.Items)
        {
            var filePath = await TryLoadFilePathAsync(item.ItemProvider);
            if (!string.IsNullOrWhiteSpace(filePath) && IsSupportedAudioFile(filePath))
            {
                return filePath;
            }
        }

        return null;
    }

    private static async Task<string?> TryLoadFilePathAsync(NSItemProvider itemProvider)
    {
        var registeredTypeIdentifiers = itemProvider.RegisteredTypeIdentifiers ?? [];
        DesktopDiagnostics.LogInfo(
            $"Drop item provider: suggestedName='{itemProvider.SuggestedName ?? "(null)"}', types=[{string.Join(", ", registeredTypeIdentifiers)}]");

        var candidateTypeIdentifiers = SupportedDropTypeIdentifiers
            .Concat(registeredTypeIdentifiers)
            .Distinct(StringComparer.Ordinal);

        foreach (var typeIdentifier in candidateTypeIdentifiers)
        {
            if (!itemProvider.HasItemConformingTo(typeIdentifier) &&
                !registeredTypeIdentifiers.Contains(typeIdentifier, StringComparer.Ordinal))
            {
                continue;
            }

            var filePath = await TryLoadFilePathAsync(itemProvider, typeIdentifier);
            if (!string.IsNullOrWhiteSpace(filePath))
            {
                return filePath;
            }
        }

        return null;
    }

    private static async Task<string?> TryLoadFilePathAsync(NSItemProvider itemProvider, string typeIdentifier)
    {
        try
        {
            var inPlaceResult = await itemProvider.LoadInPlaceFileRepresentationAsync(typeIdentifier);
            var inPlacePath = ExtractLocalPath(inPlaceResult.FileUrl);
            if (!string.IsNullOrWhiteSpace(inPlacePath))
            {
                DesktopDiagnostics.LogInfo(
                    $"Resolved dropped file via in-place representation '{typeIdentifier}': {inPlacePath}");
                return inPlacePath;
            }
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogInfo(
                $"LoadInPlaceFileRepresentationAsync failed for '{typeIdentifier}': {ex.Message}");
        }

        try
        {
            var item = await LoadItemAsync(itemProvider, typeIdentifier);
            var itemPath = ExtractLocalPath(item);
            if (!string.IsNullOrWhiteSpace(itemPath))
            {
                DesktopDiagnostics.LogInfo($"Resolved dropped file via LoadItem '{typeIdentifier}': {itemPath}");
                return itemPath;
            }
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogInfo($"LoadItem failed for '{typeIdentifier}': {ex.Message}");
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

    private sealed class NativeFileDropDelegate : UIDropInteractionDelegate
    {
        private static readonly string[] SupportedTypeIdentifiers =
        [
            "public.file-url",
            "com.apple.file-url",
            "com.apple.pasteboard.promised-file-url",
            "public.url",
            "public.audio",
            "public.audiovisual-content",
            "public.content",
            "public.data",
            "public.item"
        ];

        private readonly MainPage _page;

        public NativeFileDropDelegate(MainPage page)
        {
            _page = page;
        }

        public override bool CanHandleSession(UIDropInteraction interaction, IUIDropSession session)
        {
            var canHandle = session.Items.Length > 0;
            DesktopDiagnostics.LogInfo(
                $"Native drop CanHandleSession={canHandle}; items={DescribeSession(session)}");
            return canHandle;
        }

        public override void SessionDidEnter(UIDropInteraction interaction, IUIDropSession session)
        {
            DesktopDiagnostics.LogInfo($"Native drop SessionDidEnter; items={DescribeSession(session)}");
        }

        public override UIDropProposal SessionDidUpdate(UIDropInteraction interaction, IUIDropSession session)
        {
            var operation = _page._viewModel.CanStart ? UIDropOperation.Copy : UIDropOperation.Cancel;
            DesktopDiagnostics.LogInfo($"Native drop SessionDidUpdate; operation={operation}");
            return new(operation);
        }

        public override void PerformDrop(UIDropInteraction interaction, IUIDropSession session)
        {
            DesktopDiagnostics.LogInfo("Native drop PerformDrop invoked.");
            _ = _page.HandleNativeDropAsync(session);
        }

        private static string DescribeSession(IUIDropSession session)
            => string.Join(
                " | ",
                session.Items.Select(item =>
                {
                    var provider = item.ItemProvider;
                    var types = provider.RegisteredTypeIdentifiers ?? [];
                    return $"{provider.SuggestedName ?? "(unnamed)"} [{string.Join(", ", types)}]";
                }));
    }
#endif

    private static readonly string[] SupportedDropTypeIdentifiers =
    [
        "public.file-url",
        "com.apple.file-url",
        "com.apple.pasteboard.promised-file-url",
        "public.url",
        "public.audio",
        "public.audiovisual-content",
        "public.content",
        "public.data",
        "public.item"
    ];

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

    private static bool IsSupportedAudioFile(string filePath) => SupportedInputFormats.IsSupported(filePath);
}
