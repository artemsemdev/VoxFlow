#if DEBUG && MACCATALYST
using System.Text.Json;
using Microsoft.AspNetCore.Components.WebView;
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Maui.ApplicationModel;
using WebKit;

namespace VoxFlow.Desktop.Automation;

internal sealed class DesktopUiAutomationHost : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _sessionId;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task _processingLoop;
    private readonly object _sync = new();
    private WKWebView? _webView;
    private bool _readyFileWritten;

    private DesktopUiAutomationHost(string sessionId, BlazorWebView blazorWebView)
    {
        _sessionId = sessionId;
        Log($"Starting automation host for session '{sessionId}'.");
        blazorWebView.BlazorWebViewInitialized += HandleBlazorWebViewInitialized;
        TryAttachFromHandler(blazorWebView);
        _processingLoop = Task.Run(() => ProcessRequestsAsync(_shutdown.Token));
    }

    public static DesktopUiAutomationHost? TryStart(BlazorWebView blazorWebView)
    {
        var session = TryLoadSession();
        if (session is null)
        {
            Log("No active automation session file found. Bridge stays disabled.");
            return null;
        }

        Directory.CreateDirectory(DesktopUiAutomationPaths.RootDirectory);
        Directory.CreateDirectory(DesktopUiAutomationPaths.RequestsDirectory);
        Directory.CreateDirectory(DesktopUiAutomationPaths.ResponsesDirectory);

        CleanupSessionArtifacts(session.SessionId);
        Log($"Loaded automation session '{session.SessionId}'.");
        return new DesktopUiAutomationHost(session.SessionId, blazorWebView);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            _shutdown.Cancel();
            await _processingLoop;
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown path.
        }
        finally
        {
            _shutdown.Dispose();
        }
    }

    private static DesktopUiAutomationSession? TryLoadSession()
    {
        if (!File.Exists(DesktopUiAutomationPaths.SessionFilePath))
        {
            return null;
        }

        try
        {
            var json = File.ReadAllText(DesktopUiAutomationPaths.SessionFilePath);
            return JsonSerializer.Deserialize<DesktopUiAutomationSession>(json, JsonOptions);
        }
        catch (Exception ex)
        {
            Log($"Failed to read automation session file: {ex}");
            return null;
        }
    }

    private static void CleanupSessionArtifacts(string sessionId)
    {
        var readyFilePath = DesktopUiAutomationPaths.ReadyFilePath(sessionId);
        if (File.Exists(readyFilePath))
        {
            File.Delete(readyFilePath);
        }

        foreach (var filePath in Directory.EnumerateFiles(
                     DesktopUiAutomationPaths.RequestsDirectory,
                     $"request-{sessionId}-*.json"))
        {
            File.Delete(filePath);
        }

        foreach (var filePath in Directory.EnumerateFiles(
                     DesktopUiAutomationPaths.ResponsesDirectory,
                     $"response-{sessionId}-*.json"))
        {
            File.Delete(filePath);
        }
    }

    private void HandleBlazorWebViewInitialized(object? sender, BlazorWebViewInitializedEventArgs e)
    {
        Log("BlazorWebViewInitialized event received.");
        AttachWebView(e.WebView);
    }

    private void TryAttachFromHandler(BlazorWebView blazorWebView)
    {
        if (blazorWebView.Handler?.PlatformView is WKWebView webView)
        {
            Log("WKWebView was already available via BlazorWebView.Handler.PlatformView.");
            AttachWebView(webView);
            return;
        }

        Log("WKWebView is not available yet. Waiting for BlazorWebViewInitialized.");
    }

    private void AttachWebView(WKWebView webView)
    {
        lock (_sync)
        {
            _webView = webView;
            if (_readyFileWritten)
            {
                Log("Ready file was already written. Skipping duplicate attach.");
                return;
            }

            // The bridge is only ready once the native web view exists; the window can appear before the DOM is interactive.
            var readyJson = JsonSerializer.Serialize(
                new DesktopUiAutomationSession(_sessionId, DateTimeOffset.UtcNow),
                JsonOptions);
            File.WriteAllText(DesktopUiAutomationPaths.ReadyFilePath(_sessionId), readyJson);
            _readyFileWritten = true;
            Log($"Ready file written: {DesktopUiAutomationPaths.ReadyFilePath(_sessionId)}");
        }
    }

    private async Task ProcessRequestsAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            foreach (var requestPath in Directory.EnumerateFiles(
                         DesktopUiAutomationPaths.RequestsDirectory,
                         $"request-{_sessionId}-*.json").OrderBy(Path.GetFileName, StringComparer.Ordinal))
            {
                await ProcessRequestAsync(requestPath, cancellationToken);
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
        }
    }

    private async Task ProcessRequestAsync(string requestPath, CancellationToken cancellationToken)
    {
        DesktopUiAutomationCommand? command = null;

        try
        {
            var json = await File.ReadAllTextAsync(requestPath, cancellationToken);
            command = JsonSerializer.Deserialize<DesktopUiAutomationCommand>(json, JsonOptions)
                ?? throw new InvalidOperationException("Automation command payload was empty.");

            if (!string.Equals(command.SessionId, _sessionId, StringComparison.Ordinal))
            {
                Log($"Ignoring command '{requestPath}' for session '{command.SessionId}'.");
                return;
            }

            Log($"Processing command '{command.Kind}' ({command.CommandId}).");
            var payload = await ExecuteCommandAsync(command, cancellationToken);
            await WriteResponseAsync(
                new DesktopUiAutomationResponse(command.SessionId, command.CommandId, true, payload),
                cancellationToken);
            Log($"Command '{command.Kind}' ({command.CommandId}) completed.");
        }
        catch (Exception ex)
        {
            if (command is not null)
            {
                await WriteResponseAsync(
                    new DesktopUiAutomationResponse(command.SessionId, command.CommandId, false, Error: ex.Message),
                    cancellationToken);
            }

            Log($"Command processing failed: {ex}");
        }
        finally
        {
            if (File.Exists(requestPath))
            {
                File.Delete(requestPath);
            }
        }
    }

    private async Task WriteResponseAsync(DesktopUiAutomationResponse response, CancellationToken cancellationToken)
    {
        var responsePath = DesktopUiAutomationPaths.ResponseFilePath(response.SessionId, response.CommandId);
        var temporaryPath = $"{responsePath}.tmp";
        var json = JsonSerializer.Serialize(response, JsonOptions);
        // Write responses atomically so the polling test client never reads a half-written payload.
        await File.WriteAllTextAsync(temporaryPath, json, cancellationToken);
        File.Move(temporaryPath, responsePath, overwrite: true);
    }

    private async Task<string> ExecuteCommandAsync(
        DesktopUiAutomationCommand command,
        CancellationToken cancellationToken)
    {
        return command.Kind switch
        {
            "snapshot" => await CreateSnapshotAsync(cancellationToken),
            "click" => await ClickAsync(command.Selector, cancellationToken),
            _ => throw new InvalidOperationException($"Unsupported automation command kind '{command.Kind}'.")
        };
    }

    private async Task<string> CreateSnapshotAsync(CancellationToken cancellationToken)
    {
        var script =
            """
            (function () {
                const trackedIds = [
                    "ready-screen",
                    "browse-files-button",
                    "file-selection-error",
                    "startup-error-screen",
                    "startup-retry-button",
                    "startup-validation-message",
                    "startup-warning-message",
                    "running-screen",
                    "running-file-name",
                    "running-stage",
                    "running-percent",
                    "running-starting-label",
                    "cancel-transcription-button",
                    "failed-screen",
                    "transcription-error-message",
                    "retry-transcription-button",
                    "choose-different-file-button",
                    "complete-screen",
                    "back-to-ready-button",
                    "result-file-name",
                    "result-language",
                    "transcript-preview",
                    "preview-truncation-notice",
                    "preview-unavailable",
                    "open-folder-button",
                    "copy-text-button",
                    "action-error-message"
                ];

                const isVisible = (el) => {
                    if (!el) {
                        return false;
                    }

                    const style = window.getComputedStyle(el);
                    return style.display !== "none" && style.visibility !== "hidden";
                };

                const activeScreenId = ["startup-error-screen", "ready-screen", "running-screen", "failed-screen", "complete-screen"]
                    .find((id) => isVisible(document.getElementById(id))) ?? null;

                const visibleElementIds = trackedIds
                    .filter((id) => isVisible(document.getElementById(id)));

                return JSON.stringify({
                    activeScreenId,
                    bodyText: document.body ? (document.body.innerText || "") : "",
                    visibleElementIds
                });
            })();
            """;

        var json = await EvaluateRequiredAsync(script, cancellationToken);
        if (string.IsNullOrWhiteSpace(json))
        {
            return JsonSerializer.Serialize(
                new DesktopUiDomSnapshot(null, string.Empty, Array.Empty<string>()),
                JsonOptions);
        }

        return json;
    }

    private async Task<string> ClickAsync(string? selector, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(selector))
        {
            throw new InvalidOperationException("A selector is required for click automation.");
        }

        var selectorLiteral = JsonSerializer.Serialize(selector, JsonOptions);
        var script =
            $$"""
            (function () {
                const selector = {{selectorLiteral}};
                const element = document.querySelector(selector);
                if (!element) {
                    return JSON.stringify({ clicked: false });
                }

                element.scrollIntoView({ block: "center", inline: "center" });
                if (typeof element.focus === "function") {
                    element.focus({ preventScroll: true });
                }

                element.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, cancelable: true }));
                element.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
                element.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, cancelable: true }));
                element.click();

                return JSON.stringify({ clicked: true });
            })();
            """;

        var json = await EvaluateRequiredAsync(script, cancellationToken);
        using var document = JsonDocument.Parse(json);
        var clicked = document.RootElement.TryGetProperty("clicked", out var clickedProperty) &&
                      clickedProperty.GetBoolean();
        if (!clicked)
        {
            throw new InvalidOperationException($"Element '{selector}' was not found in the BlazorWebView DOM.");
        }

        return json;
    }

    private async Task<string> EvaluateRequiredAsync(string script, CancellationToken cancellationToken)
    {
        var result = await MainThread.InvokeOnMainThreadAsync(
            async () =>
            {
                var webView = GetWebViewOrThrow();
                return await webView.EvaluateJavaScriptAsync(script);
            });

        cancellationToken.ThrowIfCancellationRequested();
        return result?.ToString() ?? string.Empty;
    }

    private WKWebView GetWebViewOrThrow()
    {
        lock (_sync)
        {
            return _webView
                   ?? throw new InvalidOperationException("The BlazorWebView has not been initialized yet.");
        }
    }

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(DesktopUiAutomationPaths.RootDirectory);
            File.AppendAllText(
                DesktopUiAutomationPaths.BridgeLogPath,
                $"[{DateTimeOffset.UtcNow:O}] {message}{Environment.NewLine}");
        }
        catch
        {
            // Diagnostics should not break the app.
        }
    }
}
#endif
