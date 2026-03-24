using System.Text;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class MacUiAutomation
{
    private readonly string _processName;
    private readonly DesktopUiAutomationBridgeClient _bridge;

    public MacUiAutomation(string processName, DesktopUiAutomationBridgeClient bridge)
    {
        _processName = processName;
        _bridge = bridge;
    }

    public Task WaitForProcessAsync(TimeSpan timeout, CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var output = await RunAppleScriptCheckedAsync(
                    $$"""
                    tell application "System Events"
                        set matchingProcesses to every process whose name is "{{EscapeAppleScriptString(_processName)}}"
                        if (count of matchingProcesses) > 0 then
                            return "true"
                        end if
                        return "false"
                    end tell
                    """,
                    token);

                return output.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
            },
            timeout,
            $"Timed out waiting for the UI process '{_processName}' to appear.",
            cancellationToken);

    public async Task EnsureAccessibilityAccessAsync(CancellationToken cancellationToken)
    {
        try
        {
            await RunAppleScriptCheckedAsync(
                $$"""
                tell application "System Events"
                    tell (first process whose name is "{{EscapeAppleScriptString(_processName)}}")
                        return count of windows
                    end tell
                end tell
                """,
                cancellationToken);
        }
        catch (Exception ex) when (ex.Message.Contains("assistive access", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "macOS Accessibility access is required for real UI automation. Grant Accessibility access to Terminal, your IDE, and the spawned dotnet/osascript host in System Settings > Privacy & Security > Accessibility, then rerun the Desktop UI tests.",
                ex);
        }
    }

    public Task WaitForMainWindowAsync(TimeSpan timeout, CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var count = await RunAppleScriptCheckedAsync(
                    $$"""
                    tell application "System Events"
                        tell (first process whose name is "{{EscapeAppleScriptString(_processName)}}")
                            return count of windows
                        end tell
                    end tell
                    """,
                    token);

                return int.TryParse(count.Trim(), out var windowCount) && windowCount > 0;
            },
            timeout,
            "Timed out waiting for the VoxFlow Desktop main window to appear.",
            cancellationToken);

    public Task WaitForVisibleTextAsync(string expectedText, TimeSpan timeout, CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var snapshot = await _bridge.GetSnapshotAsync(token);
                return snapshot.BodyText.Contains(expectedText, StringComparison.OrdinalIgnoreCase);
            },
            timeout,
            $"Timed out waiting for text '{expectedText}' to appear in the Desktop UI.",
            cancellationToken,
            DescribeCurrentDomStateAsync);

    public Task WaitForActiveScreenAsync(string screenId, TimeSpan timeout, CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var snapshot = await _bridge.GetSnapshotAsync(token);
                return string.Equals(snapshot.ActiveScreenId, screenId, StringComparison.Ordinal);
            },
            timeout,
            $"Timed out waiting for screen '{screenId}' to become active in the Desktop UI.",
            cancellationToken,
            DescribeCurrentDomStateAsync);

    public Task WaitForVisibleElementAsync(string elementId, TimeSpan timeout, CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var snapshot = await _bridge.GetSnapshotAsync(token);
                return snapshot.VisibleElementIds.Contains(elementId, StringComparer.Ordinal);
            },
            timeout,
            $"Timed out waiting for DOM element '{elementId}' to become visible in the Desktop UI.",
            cancellationToken,
            DescribeCurrentDomStateAsync);

    public Task WaitForAnyVisibleTextAsync(
        IReadOnlyList<string> expectedTexts,
        TimeSpan timeout,
        CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var snapshot = await _bridge.GetSnapshotAsync(token);
                return expectedTexts.Any(text => snapshot.BodyText.Contains(text, StringComparison.OrdinalIgnoreCase));
            },
            timeout,
            $"Timed out waiting for any of the expected texts to appear: {string.Join(", ", expectedTexts)}.",
            cancellationToken,
            DescribeCurrentDomStateAsync);

    public async Task ClickElementAsync(string selector, CancellationToken cancellationToken)
    {
        UiProgressLogger.Write($"Trying to click DOM element: {selector}");
        await _bridge.ClickAsync(selector, cancellationToken);
        UiProgressLogger.Write($"Clicked DOM element: {selector}");
    }

    public async Task SelectFileInOpenPanelAsync(string filePath, CancellationToken cancellationToken)
    {
        UiProgressLogger.Write("Waiting for the native Open dialog.");
        await WaitUntilAsync(
            async token =>
            {
                var output = await RunAppleScriptCheckedAsync(
                    $$"""
                    tell application "System Events"
                        tell (first process whose name is "{{EscapeAppleScriptString(_processName)}}")
                            if (count of windows) > 1 then
                                return "true"
                            end if

                            try
                                if (count of sheets of window 1) > 0 then
                                    return "true"
                                end if
                            end try

                            return "false"
                        end tell
                    end tell
                    """,
                    token);

                return output.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
            },
            TimeSpan.FromSeconds(15),
            "Timed out waiting for the native Open dialog to appear.",
            cancellationToken);

        UiProgressLogger.Write($"Sending file path to the native Open dialog: {filePath}");
        await RunAppleScriptCheckedAsync(
            $$"""
            tell application "System Events"
                tell (first process whose name is "{{EscapeAppleScriptString(_processName)}}")
                    set frontmost to true
                end tell

                keystroke "g" using {command down, shift down}
                delay 0.4
                keystroke "{{EscapeAppleScriptString(filePath)}}"
                delay 0.2
                key code 36
                delay 0.6
                key code 36
            end tell
            """,
            cancellationToken);
    }

    public async Task<string> GetAccessibilitySnapshotAsync(CancellationToken cancellationToken)
    {
        var domSnapshot = await _bridge.GetSnapshotAsync(cancellationToken);
        var nativeSnapshot = await GetNativeAccessibilitySnapshotAsync(cancellationToken);
        var builder = new StringBuilder();
        builder.AppendLine($"DOM|ActiveScreen|{domSnapshot.ActiveScreenId ?? "(none)"}");
        builder.AppendLine($"DOM|VisibleIds|{string.Join(",", domSnapshot.VisibleElementIds)}");
        builder.AppendLine("DOM|BodyText|");
        builder.AppendLine(domSnapshot.BodyText);
        builder.AppendLine();
        builder.AppendLine("AX|Snapshot|");
        builder.Append(nativeSnapshot);
        return builder.ToString().TrimEnd();
    }

    public async Task CaptureScreenshotAsync(string destinationPath, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath) ?? RepositoryLayout.UiArtifactsRoot);
        await CommandRunner.RunCheckedAsync(
            "screencapture",
            ["-x", destinationPath],
            cancellationToken: cancellationToken,
            timeout: TimeSpan.FromSeconds(15));
    }

    public async Task<string> GetClipboardTextAsync(CancellationToken cancellationToken)
    {
        var output = await CommandRunner.RunCheckedAsync(
            "pbpaste",
            Array.Empty<string>(),
            cancellationToken: cancellationToken,
            timeout: TimeSpan.FromSeconds(10));
        return output.Trim();
    }

    public Task<DesktopUiDomSnapshot> GetDomSnapshotAsync(CancellationToken cancellationToken)
        => _bridge.GetSnapshotAsync(cancellationToken);

    private Task<string> GetNativeAccessibilitySnapshotAsync(CancellationToken cancellationToken)
        => RunAppleScriptCheckedAsync(
            $$"""
            tell application "System Events"
                tell (first process whose name is "{{EscapeAppleScriptString(_processName)}}")
                    if (count of windows) is 0 then
                        return ""
                    end if

                    set outputLines to {"WINDOW|" & (name of window 1 as text)}
                    repeat with el in (entire contents of window 1)
                        set roleText to ""
                        set nameText to ""
                        set valueText to ""
                        set descriptionText to ""

                        try
                            set roleText to (role of el as text)
                        end try

                        try
                            set nameText to (name of el as text)
                        end try

                        try
                            set valueText to (value of el as text)
                        end try

                        try
                            set descriptionText to (description of el as text)
                        end try

                        if roleText is not "" or nameText is not "" or valueText is not "" or descriptionText is not "" then
                            set end of outputLines to roleText & "|" & nameText & "|" & valueText & "|" & descriptionText
                        end if
                    end repeat

                    set AppleScript's text item delimiters to linefeed
                    return outputLines as text
                end tell
            end tell
            """,
            cancellationToken);

    private static async Task WaitUntilAsync(
        Func<CancellationToken, Task<bool>> condition,
        TimeSpan timeout,
        string timeoutMessage,
        CancellationToken cancellationToken,
        Func<CancellationToken, Task<string?>>? progressDetails = null)
    {
        UiProgressLogger.Write($"{timeoutMessage} Waiting up to {timeout.TotalSeconds:F0}s.");
        var deadline = DateTimeOffset.UtcNow + timeout;
        Exception? lastException = null;
        var startedAt = DateTimeOffset.UtcNow;
        var nextHeartbeatAt = startedAt.AddSeconds(5);

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                if (await condition(cancellationToken))
                {
                    UiProgressLogger.Write(
                        $"Wait completed after {(DateTimeOffset.UtcNow - startedAt).TotalSeconds:F1}s.");
                    return;
                }
            }
            catch (Exception ex)
            {
                lastException = ex;
            }

            if (DateTimeOffset.UtcNow >= nextHeartbeatAt)
            {
                var message = $"Still waiting... elapsed {(DateTimeOffset.UtcNow - startedAt).TotalSeconds:F1}s.";
                if (progressDetails is not null)
                {
                    try
                    {
                        var details = await progressDetails(cancellationToken);
                        if (!string.IsNullOrWhiteSpace(details))
                        {
                            message = $"{message} Current state: {details}";
                        }
                    }
                    catch
                    {
                        // Best-effort diagnostics only.
                    }
                }

                UiProgressLogger.Write(message);
                nextHeartbeatAt = DateTimeOffset.UtcNow.AddSeconds(5);
            }

            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken);
        }

        UiProgressLogger.Write($"Wait timed out after {(DateTimeOffset.UtcNow - startedAt).TotalSeconds:F1}s.");
        throw lastException is null
            ? new TimeoutException(timeoutMessage)
            : new TimeoutException(timeoutMessage, lastException);
    }

    private static async Task<string> RunAppleScriptCheckedAsync(string script, CancellationToken cancellationToken)
    {
        var result = await CommandRunner.RunAsync(
            "osascript",
            Array.Empty<string>(),
            stdIn: script,
            cancellationToken: cancellationToken,
            timeout: TimeSpan.FromSeconds(10));

        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"AppleScript failed with exit code {result.ExitCode}.{Environment.NewLine}{result.StandardError.Trim()}");
        }

        return result.StandardOutput.Trim();
    }

    private static string EscapeAppleScriptString(string value)
        => value.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);

    private async Task<string?> DescribeCurrentDomStateAsync(CancellationToken cancellationToken)
    {
        var snapshot = await _bridge.GetSnapshotAsync(cancellationToken);
        var visibleIds = snapshot.VisibleElementIds.Count == 0
            ? "(none)"
            : string.Join(",", snapshot.VisibleElementIds);

        var text = snapshot.BodyText
            .Replace(Environment.NewLine, " ", StringComparison.Ordinal)
            .Replace("\n", " ", StringComparison.Ordinal)
            .Trim();

        if (text.Length > 120)
        {
            text = $"{text[..120]}...";
        }

        return $"screen={snapshot.ActiveScreenId ?? "(none)"}, ids={visibleIds}, text='{text}'";
    }
}
