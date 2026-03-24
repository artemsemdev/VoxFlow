using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class DesktopUiAutomationBridgeClient : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _sessionId;

    public DesktopUiAutomationBridgeClient(string sessionId)
    {
        _sessionId = sessionId;
    }

    public static DesktopUiAutomationBridgeClient CreateAndPrepare()
    {
        var sessionId = Guid.NewGuid().ToString("N");
        var client = new DesktopUiAutomationBridgeClient(sessionId);
        client.PrepareSessionFiles();
        return client;
    }

    public async Task WaitForReadyAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        var readyFilePath = GetReadyFilePath(_sessionId);
        var deadline = DateTimeOffset.UtcNow + timeout;

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(readyFilePath))
            {
                return;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(150), cancellationToken);
        }

        throw new TimeoutException(
            $"Timed out waiting for the Desktop UI automation bridge to become ready for session '{_sessionId}'.");
    }

    public Task<DesktopUiDomSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
        => SendCommandAsync<DesktopUiDomSnapshot>("snapshot", null, cancellationToken);

    public Task ClickAsync(string selector, CancellationToken cancellationToken)
        => SendCommandAsync<JsonElement>("click", selector, cancellationToken);

    public ValueTask DisposeAsync()
    {
        TryDelete(RepositoryLayout.DesktopUiAutomationSessionFilePath);
        TryDelete(GetReadyFilePath(_sessionId));

        foreach (var filePath in Directory.EnumerateFiles(
                     RepositoryLayout.DesktopUiAutomationRequestsDirectory,
                     $"request-{_sessionId}-*.json"))
        {
            TryDelete(filePath);
        }

        foreach (var filePath in Directory.EnumerateFiles(
                     RepositoryLayout.DesktopUiAutomationResponsesDirectory,
                     $"response-{_sessionId}-*.json"))
        {
            TryDelete(filePath);
        }

        return ValueTask.CompletedTask;
    }

    private void PrepareSessionFiles()
    {
        Directory.CreateDirectory(RepositoryLayout.DesktopUiAutomationRootPath);
        Directory.CreateDirectory(RepositoryLayout.DesktopUiAutomationRequestsDirectory);
        Directory.CreateDirectory(RepositoryLayout.DesktopUiAutomationResponsesDirectory);

        TryDelete(RepositoryLayout.DesktopUiAutomationSessionFilePath);
        TryDelete(GetReadyFilePath(_sessionId));

        var session = new DesktopUiAutomationSession(_sessionId, DateTimeOffset.UtcNow);
        var sessionJson = JsonSerializer.Serialize(session, JsonOptions);
        File.WriteAllText(RepositoryLayout.DesktopUiAutomationSessionFilePath, sessionJson);
    }

    private async Task<T> SendCommandAsync<T>(
        string kind,
        string? selector,
        CancellationToken cancellationToken)
    {
        var commandId = Guid.NewGuid().ToString("N");
        var command = new DesktopUiAutomationCommand(_sessionId, commandId, kind, selector);
        var requestPath = GetRequestFilePath(_sessionId, commandId);
        var temporaryRequestPath = $"{requestPath}.tmp";
        var responsePath = GetResponseFilePath(_sessionId, commandId);

        var commandJson = JsonSerializer.Serialize(command, JsonOptions);
        await File.WriteAllTextAsync(temporaryRequestPath, commandJson, cancellationToken);
        File.Move(temporaryRequestPath, requestPath, overwrite: true);

        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(20);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(responsePath))
            {
                var responseJson = await File.ReadAllTextAsync(responsePath, cancellationToken);
                if (string.IsNullOrWhiteSpace(responseJson))
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                    continue;
                }
                DesktopUiAutomationResponse response;
                try
                {
                    response = JsonSerializer.Deserialize<DesktopUiAutomationResponse>(responseJson, JsonOptions)
                        ?? throw new InvalidOperationException("Automation bridge returned an empty response.");
                }
                catch (JsonException)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                    continue;
                }

                TryDelete(responsePath);

                if (!response.Success)
                {
                    throw new InvalidOperationException(
                        $"Desktop UI automation bridge command '{kind}' failed: {response.Error}");
                }

                if (typeof(T) == typeof(JsonElement))
                {
                    var payloadJson = string.IsNullOrWhiteSpace(response.Payload) ? "{}" : response.Payload;
                    return (T)(object)JsonDocument.Parse(payloadJson).RootElement.Clone();
                }

                if (typeof(T) == typeof(DesktopUiDomSnapshot) && string.IsNullOrWhiteSpace(response.Payload))
                {
                    return (T)(object)new DesktopUiDomSnapshot(null, string.Empty, Array.Empty<string>());
                }

                return JsonSerializer.Deserialize<T>(response.Payload ?? throw new InvalidOperationException(
                    $"Desktop UI automation bridge command '{kind}' returned no payload."), JsonOptions)
                    ?? throw new InvalidOperationException(
                        $"Desktop UI automation bridge command '{kind}' returned an unreadable payload.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
        }

        throw new TimeoutException(
            $"Timed out waiting for Desktop UI automation bridge response to command '{kind}'.");
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best-effort cleanup is sufficient for test automation artifacts.
        }
    }

    private static string GetReadyFilePath(string sessionId)
        => Path.Combine(RepositoryLayout.DesktopUiAutomationRootPath, $"ready-{sessionId}.json");

    private static string GetRequestFilePath(string sessionId, string commandId)
        => Path.Combine(RepositoryLayout.DesktopUiAutomationRequestsDirectory, $"request-{sessionId}-{commandId}.json");

    private static string GetResponseFilePath(string sessionId, string commandId)
        => Path.Combine(RepositoryLayout.DesktopUiAutomationResponsesDirectory, $"response-{sessionId}-{commandId}.json");
}

internal sealed record DesktopUiAutomationSession(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("createdAtUtc")] DateTimeOffset CreatedAtUtc);

internal sealed record DesktopUiAutomationCommand(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("commandId")] string CommandId,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("selector")] string? Selector = null);

internal sealed record DesktopUiAutomationResponse(
    [property: JsonPropertyName("sessionId")] string SessionId,
    [property: JsonPropertyName("commandId")] string CommandId,
    [property: JsonPropertyName("success")] bool Success,
    [property: JsonPropertyName("payload")] string? Payload = null,
    [property: JsonPropertyName("error")] string? Error = null);

internal sealed record DesktopUiDomSnapshot(
    [property: JsonPropertyName("activeScreenId")] string? ActiveScreenId,
    [property: JsonPropertyName("bodyText")] string BodyText,
    [property: JsonPropertyName("visibleElementIds")] IReadOnlyList<string> VisibleElementIds);
