using System.Text;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class MacUiAutomation
{
    private readonly int _pid;

    public MacUiAutomation(int pid)
    {
        _pid = pid;
    }

    public async Task EnsureAccessibilityAccessAsync(CancellationToken cancellationToken)
    {
        try
        {
            await RunAppleScriptCheckedAsync(
                $$"""
                tell application "System Events"
                    tell (first process whose unix id is {{_pid}})
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
                        tell (first process whose unix id is {{_pid}})
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
                var snapshot = await GetAccessibilitySnapshotAsync(token);
                return snapshot.Contains(expectedText, StringComparison.OrdinalIgnoreCase);
            },
            timeout,
            $"Timed out waiting for text '{expectedText}' to appear in the Desktop UI.",
            cancellationToken);

    public Task WaitForAnyVisibleTextAsync(
        IReadOnlyList<string> expectedTexts,
        TimeSpan timeout,
        CancellationToken cancellationToken)
        => WaitUntilAsync(
            async token =>
            {
                var snapshot = await GetAccessibilitySnapshotAsync(token);
                return expectedTexts.Any(text => snapshot.Contains(text, StringComparison.OrdinalIgnoreCase));
            },
            timeout,
            $"Timed out waiting for any of the expected texts to appear: {string.Join(", ", expectedTexts)}.",
            cancellationToken);

    public async Task ClickButtonAsync(IReadOnlyList<string> candidateLabels, CancellationToken cancellationToken)
    {
        foreach (var label in candidateLabels)
        {
            var pressed = await TryClickButtonAsync(label, cancellationToken);
            if (pressed)
            {
                return;
            }
        }

        throw new InvalidOperationException(
            $"Could not find a clickable button with any of these labels: {string.Join(", ", candidateLabels)}.");
    }

    public async Task SelectFileInOpenPanelAsync(string filePath, CancellationToken cancellationToken)
    {
        await WaitUntilAsync(
            async token =>
            {
                var output = await RunAppleScriptCheckedAsync(
                    $$"""
                    tell application "System Events"
                        tell (first process whose unix id is {{_pid}})
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

        await RunAppleScriptCheckedAsync(
            $$"""
            tell application "System Events"
                tell (first process whose unix id is {{_pid}})
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

    public Task<string> GetAccessibilitySnapshotAsync(CancellationToken cancellationToken)
        => RunAppleScriptCheckedAsync(
            $$"""
            tell application "System Events"
                tell (first process whose unix id is {{_pid}})
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

    private async Task<bool> TryClickButtonAsync(string candidateLabel, CancellationToken cancellationToken)
    {
        var output = await RunAppleScriptCheckedAsync(
            $$"""
            on matchesLabel(targetLabel, candidateValue)
                if candidateValue is missing value then
                    return false
                end if

                return (candidateValue as text) is targetLabel
            end matchesLabel

            tell application "System Events"
                tell (first process whose unix id is {{_pid}})
                    set frontmost to true

                    if (count of windows) is 0 then
                        return "false"
                    end if

                    set targetElement to missing value
                    repeat with el in (entire contents of window 1)
                        try
                            if role of el is "AXButton" then
                                if my matchesLabel("{{EscapeAppleScriptString(candidateLabel)}}", name of el) then
                                    set targetElement to el
                                    exit repeat
                                end if

                                if my matchesLabel("{{EscapeAppleScriptString(candidateLabel)}}", description of el) then
                                    set targetElement to el
                                    exit repeat
                                end if
                            end if
                        end try
                    end repeat

                    if targetElement is missing value then
                        return "false"
                    end if

                    perform action "AXPress" of targetElement
                    return "true"
                end tell
            end tell
            """,
            cancellationToken);

        return output.Trim().Equals("true", StringComparison.OrdinalIgnoreCase);
    }

    private static async Task WaitUntilAsync(
        Func<CancellationToken, Task<bool>> condition,
        TimeSpan timeout,
        string timeoutMessage,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        Exception? lastException = null;

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                if (await condition(cancellationToken))
                {
                    return;
                }
            }
            catch (Exception ex)
            {
                lastException = ex;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken);
        }

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
}
