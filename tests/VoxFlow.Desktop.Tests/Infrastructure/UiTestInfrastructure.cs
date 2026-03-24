using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.RenderTree;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.JSInterop;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.ViewModels;
using Whisper.net;

namespace VoxFlow.Desktop.Tests;

internal sealed class DesktopUiTestContext : IAsyncDisposable
{
    public DesktopUiTestContext(
        TestRenderer renderer,
        AppViewModel viewModel,
        SettingsViewModel settings,
        RecordingJsRuntime jsRuntime,
        ITranscriptionService transcriptionService)
    {
        Renderer = renderer;
        ViewModel = viewModel;
        Settings = settings;
        JsRuntime = jsRuntime;
        TranscriptionService = transcriptionService;
    }

    public TestRenderer Renderer { get; }
    public AppViewModel ViewModel { get; }
    public SettingsViewModel Settings { get; }
    public RecordingJsRuntime JsRuntime { get; }
    public ITranscriptionService TranscriptionService { get; }

    public static DesktopUiTestContext Create(
        IConfigurationService? configurationService = null,
        IValidationService? validationService = null,
        DelegateTranscriptionService? transcriptionService = null,
        IModelService? modelService = null)
    {
        VoxFlow.Desktop.Platform.MacFilePicker.Reset();
        FilePicker.Default = new FilePicker();
        Launcher.Default = new Launcher();

        var options = TranscriptionOptions.LoadFromPath(ViewModelFactory.ResolveRootSettingsPath());
        var config = configurationService ?? new DelegateConfigurationService(_ => Task.FromResult(options));
        var validation = validationService ?? new DelegateValidationService(
            (_, _) => Task.FromResult(TestValidationFactory.Create(canStart: true)));
        var transcription = transcriptionService ?? new DelegateTranscriptionService(
            (request, _, _) => Task.FromResult(TestTranscriptionFactory.Create(success: true, path: request.InputPath)));
        var models = modelService ?? new DelegateModelService(options.ModelFilePath, options.ModelType);
        var jsRuntime = new RecordingJsRuntime();

        var viewModel = new AppViewModel(transcription, validation, config, models);
        var settings = new SettingsViewModel(config);

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton<IJSRuntime>(jsRuntime);
        services.AddSingleton(viewModel);
        services.AddSingleton(settings);

        var renderer = new TestRenderer(services.BuildServiceProvider());
        return new DesktopUiTestContext(renderer, viewModel, settings, jsRuntime, transcription);
    }

    public static DesktopUiTestContext CreateWithRealCore(string configurationPath)
    {
        VoxFlow.Desktop.Platform.MacFilePicker.Reset();
        FilePicker.Default = new FilePicker();
        Launcher.Default = new Launcher();

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton<IJSRuntime, RecordingJsRuntime>();
        services.AddVoxFlowCore();
        services.AddSingleton<IConfigurationService>(new FixedConfigurationService(configurationPath));
        services.AddSingleton<AppViewModel>();
        services.AddSingleton<SettingsViewModel>();

        var provider = services.BuildServiceProvider();
        var renderer = new TestRenderer(provider);

        return new DesktopUiTestContext(
            renderer,
            provider.GetRequiredService<AppViewModel>(),
            provider.GetRequiredService<SettingsViewModel>(),
            (RecordingJsRuntime)provider.GetRequiredService<IJSRuntime>(),
            provider.GetRequiredService<ITranscriptionService>());
    }

    public Task<RenderedComponent<TComponent>> RenderAsync<TComponent>()
        where TComponent : IComponent
        => Renderer.RenderAsync<TComponent>(ParameterView.Empty);

    public Task<RenderedComponent<TComponent>> RenderAsync<TComponent>(ParameterView parameters)
        where TComponent : IComponent
        => Renderer.RenderAsync<TComponent>(parameters);

    public async ValueTask DisposeAsync()
    {
        await Renderer.DisposeAsync();
    }
}

internal sealed class TestRenderer : Renderer, IAsyncDisposable
{
    public TestRenderer(IServiceProvider serviceProvider)
        : base(serviceProvider, NullLoggerFactory.Instance)
    {
    }

    public override Dispatcher Dispatcher { get; } = Dispatcher.CreateDefault();

    public Task<RenderedComponent<TComponent>> RenderAsync<TComponent>(ParameterView parameters)
        where TComponent : IComponent
    {
        return Dispatcher.InvokeAsync(async () =>
        {
            var instance = (TComponent)InstantiateComponent(typeof(TComponent));
            var componentId = AssignRootComponentId(instance);
            await RenderRootComponentAsync(componentId, parameters);
            return new RenderedComponent<TComponent>(this, componentId, instance);
        });
    }

    public ArrayRange<RenderTreeFrame> FramesFor(int componentId) => GetCurrentRenderTreeFrames(componentId);

    public Task DispatchAsync(ulong eventHandlerId, EventArgs args)
    {
        return Dispatcher.InvokeAsync(() =>
            DispatchEventAsync(eventHandlerId, default(EventFieldInfo), args, waitForQuiescence: true));
    }

    public Task SynchronizeAsync()
    {
        return Dispatcher.InvokeAsync(static () => Task.CompletedTask);
    }

    protected override Task UpdateDisplayAsync(in RenderBatch renderBatch) => Task.CompletedTask;

    protected override void HandleException(Exception exception)
    {
        ExceptionDispatchInfo.Capture(exception).Throw();
    }
}

internal sealed class RenderedComponent<TComponent> where TComponent : IComponent
{
    private readonly TestRenderer _renderer;
    private readonly int _componentId;

    public RenderedComponent(TestRenderer renderer, int componentId, TComponent instance)
    {
        _renderer = renderer;
        _componentId = componentId;
        Instance = instance;
    }

    public TComponent Instance { get; }

    public string TextContent => NormalizeWhitespace(CollectText(_componentId));

    public IReadOnlyList<RenderedElement> FindElements(Func<RenderedElement, bool> predicate)
    {
        return EnumerateElements(_componentId)
            .Where(predicate)
            .ToArray();
    }

    public RenderedElement FindElement(Func<RenderedElement, bool> predicate, string description)
    {
        var match = FindElements(predicate).SingleOrDefault();
        return match ?? throw new InvalidOperationException($"Expected a single element matching: {description}");
    }

    public async Task ClickAsync(Func<RenderedElement, bool> predicate, string description)
    {
        var element = FindElement(predicate, description);
        if (!element.EventHandlers.TryGetValue("onclick", out var handlerId))
        {
            throw new InvalidOperationException($"Element '{description}' does not define an onclick handler.");
        }

        await _renderer.DispatchAsync(handlerId, new MouseEventArgs());
    }

    public async Task KeyDownAsync(Func<RenderedElement, bool> predicate, string description, string key)
    {
        var element = FindElement(predicate, description);
        if (!element.EventHandlers.TryGetValue("onkeydown", out var handlerId))
        {
            throw new InvalidOperationException($"Element '{description}' does not define an onkeydown handler.");
        }

        await _renderer.DispatchAsync(handlerId, new KeyboardEventArgs { Key = key });
    }

    public Task SynchronizeAsync() => _renderer.SynchronizeAsync();

    private IEnumerable<RenderedElement> EnumerateElements(int componentId)
    {
        var frames = _renderer.FramesFor(componentId);
        var buffer = frames.Array ?? [];
        return EnumerateElements(buffer, 0, frames.Count);
    }

    private IEnumerable<RenderedElement> EnumerateElements(RenderTreeFrame[] frames, int start, int end)
    {
        var index = start;
        while (index < end)
        {
            var frame = frames[index];
            switch (frame.FrameType)
            {
                case RenderTreeFrameType.Element:
                {
                    var subtreeEnd = index + frame.ElementSubtreeLength;
                    var attributes = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                    var eventHandlers = new Dictionary<string, ulong>(StringComparer.OrdinalIgnoreCase);
                    var childIndex = index + 1;

                    while (childIndex < subtreeEnd && frames[childIndex].FrameType == RenderTreeFrameType.Attribute)
                    {
                        var attribute = frames[childIndex];
                        attributes[attribute.AttributeName] = attribute.AttributeValue;
                        if (attribute.AttributeEventHandlerId != 0)
                        {
                            eventHandlers[attribute.AttributeName] = attribute.AttributeEventHandlerId;
                        }

                        childIndex++;
                    }

                    yield return new RenderedElement(
                        frame.ElementName,
                        attributes,
                        eventHandlers,
                        NormalizeWhitespace(CollectText(frames, childIndex, subtreeEnd)));

                    foreach (var child in EnumerateElements(frames, childIndex, subtreeEnd))
                    {
                        yield return child;
                    }

                    index = subtreeEnd;
                    break;
                }
                case RenderTreeFrameType.Component:
                {
                    foreach (var child in EnumerateElements(frame.ComponentId))
                    {
                        yield return child;
                    }

                    index += frame.ComponentSubtreeLength;
                    break;
                }
                case RenderTreeFrameType.Region:
                {
                    var regionEnd = index + frame.RegionSubtreeLength;
                    foreach (var child in EnumerateElements(frames, index + 1, regionEnd))
                    {
                        yield return child;
                    }

                    index = regionEnd;
                    break;
                }
                default:
                    index++;
                    break;
            }
        }
    }

    private string CollectText(int componentId)
    {
        var frames = _renderer.FramesFor(componentId);
        return CollectText(frames.Array ?? [], 0, frames.Count);
    }

    private string CollectText(RenderTreeFrame[] frames, int start, int end)
    {
        var builder = new StringBuilder();
        var index = start;

        while (index < end)
        {
            var frame = frames[index];
            switch (frame.FrameType)
            {
                case RenderTreeFrameType.Text:
                    builder.Append(' ').Append(frame.TextContent);
                    index++;
                    break;
                case RenderTreeFrameType.Markup:
                    builder.Append(' ').Append(frame.MarkupContent);
                    index++;
                    break;
                case RenderTreeFrameType.Element:
                {
                    var subtreeEnd = index + frame.ElementSubtreeLength;
                    var childIndex = index + 1;
                    while (childIndex < subtreeEnd && frames[childIndex].FrameType == RenderTreeFrameType.Attribute)
                    {
                        childIndex++;
                    }

                    builder.Append(' ').Append(CollectText(frames, childIndex, subtreeEnd));
                    index = subtreeEnd;
                    break;
                }
                case RenderTreeFrameType.Component:
                    builder.Append(' ').Append(CollectText(frame.ComponentId));
                    index += frame.ComponentSubtreeLength;
                    break;
                case RenderTreeFrameType.Region:
                {
                    var regionEnd = index + frame.RegionSubtreeLength;
                    builder.Append(' ').Append(CollectText(frames, index + 1, regionEnd));
                    index = regionEnd;
                    break;
                }
                default:
                    index++;
                    break;
            }
        }

        return builder.ToString();
    }

    private static string NormalizeWhitespace(string text)
    {
        return string.Join(
            " ",
            text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }
}

internal sealed record RenderedElement(
    string Name,
    IReadOnlyDictionary<string, object?> Attributes,
    IReadOnlyDictionary<string, ulong> EventHandlers,
    string TextContent)
{
    public bool HasClass(string className)
    {
        if (!Attributes.TryGetValue("class", out var value) || value is not string classes)
        {
            return false;
        }

        return classes
            .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Contains(className, StringComparer.Ordinal);
    }
}

internal sealed class DelegateConfigurationService : IConfigurationService
{
    private readonly Func<string?, Task<TranscriptionOptions>> _loadAsync;

    public DelegateConfigurationService(Func<string?, Task<TranscriptionOptions>> loadAsync)
    {
        _loadAsync = loadAsync;
    }

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
        => _loadAsync(configurationPath);

    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
        => LoadAsync(configurationPath).GetAwaiter().GetResult().SupportedLanguages;
}

internal sealed class FixedConfigurationService : IConfigurationService
{
    private readonly string _configurationPath;

    public FixedConfigurationService(string configurationPath)
    {
        _configurationPath = configurationPath;
    }

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
        => Task.FromResult(TranscriptionOptions.LoadFromPath(configurationPath ?? _configurationPath));

    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
        => LoadAsync(configurationPath).GetAwaiter().GetResult().SupportedLanguages;
}

internal sealed class DelegateValidationService : IValidationService
{
    private readonly Func<TranscriptionOptions, CancellationToken, Task<ValidationResult>> _validateAsync;

    public DelegateValidationService(Func<TranscriptionOptions, CancellationToken, Task<ValidationResult>> validateAsync)
    {
        _validateAsync = validateAsync;
    }

    public Task<ValidationResult> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
        => _validateAsync(options, cancellationToken);
}

internal sealed class DelegateTranscriptionService : ITranscriptionService
{
    private readonly Func<TranscribeFileRequest, IProgress<ProgressUpdate>?, CancellationToken, Task<TranscribeFileResult>> _transcribeAsync;

    public DelegateTranscriptionService(
        Func<TranscribeFileRequest, IProgress<ProgressUpdate>?, CancellationToken, Task<TranscribeFileResult>> transcribeAsync)
    {
        _transcribeAsync = transcribeAsync;
    }

    public string? LastFilePath { get; private set; }

    public Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        LastFilePath = request.InputPath;
        return _transcribeAsync(request, progress, cancellationToken);
    }
}

internal sealed class DelegateModelService : IModelService
{
    private readonly string _modelPath;
    private readonly string _modelType;

    public DelegateModelService(string modelPath, string modelType)
    {
        _modelPath = modelPath;
        _modelType = modelType;
    }

    public Task<WhisperFactory> GetOrCreateFactoryAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        return Task.FromResult<WhisperFactory>(null!);
    }

    public ModelInfo InspectModel(TranscriptionOptions options)
    {
        return new ModelInfo(_modelPath, _modelType, Exists: true, FileSizeBytes: 1024, IsLoadable: true, NeedsDownload: false);
    }
}

internal sealed class RecordingJsRuntime : IJSRuntime
{
    public List<JsInvocation> Invocations { get; } = [];

    public ValueTask<TValue> InvokeAsync<TValue>(string identifier, object?[]? args)
        => InvokeAsync<TValue>(identifier, CancellationToken.None, args);

    public ValueTask<TValue> InvokeAsync<TValue>(
        string identifier,
        CancellationToken cancellationToken,
        object?[]? args)
    {
        Invocations.Add(new JsInvocation(identifier, args ?? []));
        return ValueTask.FromResult(default(TValue)!);
    }
}

internal sealed record JsInvocation(string Identifier, IReadOnlyList<object?> Arguments);

internal static class TestValidationFactory
{
    public static ValidationResult Create(bool canStart, params ValidationCheck[] checks)
    {
        return new ValidationResult(
            Outcome: canStart ? "OK" : "Failed",
            CanStart: canStart,
            HasWarnings: checks.Any(static check => check.Status == ValidationCheckStatus.Warning),
            ResolvedConfigurationPath: "/tmp/test-appsettings.json",
            Checks: checks);
    }
}

internal static class TestTranscriptionFactory
{
    public static TranscribeFileResult Create(
        bool success,
        string? path = "/tmp/result.txt",
        IReadOnlyList<string>? warnings = null)
    {
        return new TranscribeFileResult(
            Success: success,
            DetectedLanguage: "en",
            ResultFilePath: path,
            AcceptedSegmentCount: 5,
            SkippedSegmentCount: 1,
            Duration: TimeSpan.FromSeconds(8),
            Warnings: warnings ?? Array.Empty<string>(),
            TranscriptPreview: "Hello from VoxFlow");
    }
}

internal static class AppViewModelStateAccessor
{
    public static void SetState(
        AppViewModel viewModel,
        AppState? currentState = null,
        ValidationResult? validationResult = null,
        TranscribeFileResult? transcriptionResult = null,
        ProgressUpdate? currentProgress = null,
        string? errorMessage = null,
        string? lastFilePath = null,
        bool? isDownloadingModel = null)
    {
        SetIfProvided(viewModel, "_currentState", currentState);
        SetIfProvided(viewModel, "_validationResult", validationResult);
        SetIfProvided(viewModel, "_transcriptionResult", transcriptionResult);
        SetIfProvided(viewModel, "_currentProgress", currentProgress);
        SetIfProvided(viewModel, "_errorMessage", errorMessage);
        SetIfProvided(viewModel, "_lastFilePath", lastFilePath);
        SetIfProvided(viewModel, "_isDownloadingModel", isDownloadingModel);
        viewModel.NotifyStateChanged();
    }

    private static void SetIfProvided<T>(AppViewModel viewModel, string fieldName, T value)
    {
        if (EqualityComparer<T>.Default.Equals(value, default!) && value is null)
        {
            return;
        }

        var field = typeof(AppViewModel).GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new MissingFieldException(typeof(AppViewModel).FullName, fieldName);

        field.SetValue(viewModel, value);
    }
}
