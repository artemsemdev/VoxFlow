#if DEBUG && MACCATALYST
using System.Text.Json.Serialization;

namespace VoxFlow.Desktop.Automation;

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
#endif
