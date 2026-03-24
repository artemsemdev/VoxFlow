using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Components;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Components;
using VoxFlow.Desktop.Components.Layout;
using VoxFlow.Desktop.Components.Pages;
using VoxFlow.Desktop.Components.Shared;
using Xunit;

namespace VoxFlow.Desktop.Tests;

public sealed class DesktopUiComponentTests
{
    [Fact]
    public async Task Routes_WhenInitializationFails_ShowsStartupError_AndRetryRecovers()
    {
        var options = TranscriptionOptions.LoadFromPath(ViewModelFactory.ResolveRootSettingsPath());
        var loadAttempts = 0;
        var configurationService = new DelegateConfigurationService(_ =>
        {
            loadAttempts++;
            if (loadAttempts == 1)
            {
                throw new InvalidOperationException("configuration is unreadable");
            }

            return Task.FromResult(options);
        });

        var validationService = new DelegateValidationService((_, _) =>
            Task.FromResult(TestValidationFactory.Create(
                canStart: true,
                new ValidationCheck("ffmpeg", ValidationCheckStatus.Passed, "ffmpeg is available."))));

        await using var context = DesktopUiTestContext.Create(
            configurationService: configurationService,
            validationService: validationService);

        var rendered = await context.RenderAsync<Routes>();

        Assert.Contains("Startup Failed", rendered.TextContent);
        Assert.Contains("configuration is unreadable", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Retry",
            "startup retry button");

        Assert.DoesNotContain("Startup Failed", rendered.TextContent);
        Assert.Contains("Audio Transcription", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WithProgress_ShowsDetailedProgress()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Transcribing,
                42,
                TimeSpan.FromSeconds(125),
                "Processing audio",
                "English"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("audio file", rendered.TextContent);
        Assert.Contains("Processing audio", rendered.TextContent);
        Assert.Contains("Language: English", rendered.TextContent);
        Assert.Contains("2:05", rendered.TextContent);

        var progressBar = rendered.FindElement(
            element => element.Name == "div" && element.HasClass("progress-bar"),
            "progress bar");

        Assert.Contains("42%", progressBar.Attributes["style"]?.ToString());
    }

    [Fact]
    public async Task Routes_BrowseFile_WithStubTranscription_CompletesViaRealClick()
    {
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(
                success: true,
                path: $"/tmp/{Path.GetFileNameWithoutExtension(request.InputPath)}.txt")));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/interview.m4a");

        var rendered = await context.RenderAsync<Routes>();
        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.Contains("Audio Transcription", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        var delegateTranscriptionService = Assert.IsType<DelegateTranscriptionService>(context.TranscriptionService);
        Assert.Equal("/tmp/interview.m4a", delegateTranscriptionService.LastFilePath);
        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.NotNull(context.ViewModel.TranscriptionResult);
        Assert.True(context.ViewModel.TranscriptionResult!.Success);
        Assert.Contains("interview.m4a", rendered.TextContent);
        Assert.Contains("Hello from VoxFlow", rendered.TextContent);
        Assert.Contains("Copy Text", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_WhenStartupValidationHasBlockingErrors_ShowsMessage_AndDisablesBrowse()
    {
        var validationService = new DelegateValidationService((_, _) =>
            Task.FromResult(TestValidationFactory.Create(
                canStart: false,
                new ValidationCheck(
                    "Whisper runtime",
                    ValidationCheckStatus.Failed,
                    "Whisper runtime is not supported in VoxFlow Desktop on Intel Macs."))));

        await using var context = DesktopUiTestContext.Create(validationService: validationService);
        var rendered = await context.RenderAsync<Routes>();

        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.True(context.ViewModel.HasBlockingValidationErrors);
        Assert.Contains("Intel Macs", rendered.TextContent);

        var browseButton = rendered.FindElement(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.True(browseButton.Attributes.ContainsKey("disabled"));
    }

    [Fact]
    public async Task Routes_WhenTranscriptionFails_ChooseDifferentFile_ReturnsToReady()
    {
        var transcriptionService = new DelegateTranscriptionService((_, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(success: false, warnings: ["ffmpeg crashed"])));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/demo.m4a");
        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.Equal(AppState.Failed, context.ViewModel.CurrentState);
        Assert.Contains("Transcription Failed", rendered.TextContent);
        Assert.Contains("ffmpeg crashed", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose Different File",
            "choose different file button");

        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.Contains("Audio Transcription", rendered.TextContent);
        Assert.DoesNotContain("Transcription Failed", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_WhenTranscriptionFails_Retry_ReusesLastFile_AndTransitionsToComplete()
    {
        var attempts = 0;
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(++attempts == 1
                ? TestTranscriptionFactory.Create(success: false, warnings: ["retry me"])
                : TestTranscriptionFactory.Create(success: true, path: $"/tmp/{Path.GetFileNameWithoutExtension(request.InputPath)}.txt")));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/demo.wav");
        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.Equal(AppState.Failed, context.ViewModel.CurrentState);
        Assert.Contains("Transcription Failed", rendered.TextContent);
        Assert.Contains("retry me", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Retry",
            "failed retry button");

        var delegateTranscriptionService = Assert.IsType<DelegateTranscriptionService>(context.TranscriptionService);
        Assert.Equal(2, attempts);
        Assert.Equal("/tmp/demo.wav", delegateTranscriptionService.LastFilePath);
        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.NotNull(context.ViewModel.TranscriptionResult);
        Assert.True(context.ViewModel.TranscriptionResult!.Success);
        Assert.Contains("demo.wav", rendered.TextContent);
    }

    [Theory]
    [InlineData("Test 1.m4a")]
    [InlineData("Test 2.m4a")]
    public async Task Routes_BrowseFile_WithRealAudio_CompletesTranscription(string fileName)
    {
        var repositoryRoot = Path.GetDirectoryName(ViewModelFactory.ResolveRootSettingsPath())
            ?? throw new InvalidOperationException("Could not resolve repository root.");
        var inputPath = Path.Combine(repositoryRoot, "artifacts", "Input", fileName);
        Assert.True(File.Exists(inputPath), $"Expected integration input file to exist: {inputPath}");

        var tempDir = Path.Combine(Path.GetTempPath(), $"voxflow-ui-real-{Path.GetFileNameWithoutExtension(fileName)}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        try
        {
            var configPath = WriteSingleFileConfig(repositoryRoot, tempDir, inputPath);
            await using var context = DesktopUiTestContext.CreateWithRealCore(configPath);

            VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
                () => Task.FromResult<string?>(inputPath);

            var rendered = await context.RenderAsync<Routes>();
            Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);

            await rendered.ClickAsync(
                element => element.Name == "button" && element.TextContent == "+ Browse Files",
                "browse files button");

            var resultFilePath = Path.Combine(tempDir, $"{Path.GetFileNameWithoutExtension(fileName)}.txt");

            Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
            Assert.NotNull(context.ViewModel.TranscriptionResult);
            Assert.True(context.ViewModel.TranscriptionResult!.Success);
            Assert.Equal(resultFilePath, context.ViewModel.TranscriptionResult.ResultFilePath);
            Assert.True(File.Exists(resultFilePath), $"Expected result file to exist: {resultFilePath}");
            Assert.Contains(Path.GetFileName(inputPath), rendered.TextContent);
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
            }
        }
    }

    [Fact]
    public async Task ReadyView_BrowseFile_WithRealAudio_CompletesTranscription()
    {
        var repositoryRoot = Path.GetDirectoryName(ViewModelFactory.ResolveRootSettingsPath())
            ?? throw new InvalidOperationException("Could not resolve repository root.");
        var inputPath = Path.Combine(repositoryRoot, "artifacts", "Input", "Test 1.m4a");
        Assert.True(File.Exists(inputPath), $"Expected integration input file to exist: {inputPath}");

        var tempDir = Path.Combine(Path.GetTempPath(), $"voxflow-ui-ready-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        try
        {
            var configPath = WriteSingleFileConfig(repositoryRoot, tempDir, inputPath);
            await using var context = DesktopUiTestContext.CreateWithRealCore(configPath);

            VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
                () => Task.FromResult<string?>(inputPath);

            var rendered = await context.RenderAsync<ReadyView>();

            await rendered.ClickAsync(
                element => element.Name == "button" && element.TextContent == "+ Browse Files",
                "browse files button");

            var resultFilePath = Path.Combine(tempDir, "Test 1.txt");

            Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
            Assert.NotNull(context.ViewModel.TranscriptionResult);
            Assert.True(context.ViewModel.TranscriptionResult!.Success);
            Assert.Equal(resultFilePath, context.ViewModel.TranscriptionResult.ResultFilePath);
            Assert.True(File.Exists(resultFilePath), $"Expected result file to exist: {resultFilePath}");
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
            }
        }
    }

    [Fact]
    public async Task CompleteView_CopyText_UsesClipboardInterop_AndUpdatesButton()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: "/tmp/result.txt",
                AcceptedSegmentCount: 7,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(12),
                Warnings: [],
                TranscriptPreview: "Clipboard text"));

        var rendered = await context.RenderAsync<CompleteView>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Copy Text",
            "copy text button");

        var invocation = Assert.Single(context.JsRuntime.Invocations);
        Assert.Equal("voxFlowInterop.copyToClipboard", invocation.Identifier);
        Assert.Equal("Clipboard text", Assert.Single(invocation.Arguments));
        Assert.Contains("Copied!", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_WhenTranscriptionCompletes_BackButton_ReturnsToReady()
    {
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(
                success: true,
                path: $"/tmp/{Path.GetFileNameWithoutExtension(request.InputPath)}.txt")));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/meeting_01.m4a");

        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.Contains("meeting_01.m4a", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.HasClass("result-back-btn"),
            "back button");

        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.Contains("Audio Transcription", rendered.TextContent);
        Assert.DoesNotContain("meeting_01.m4a", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_BrowseButton_InvokesCallback_WithSelectedFile()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/interview.wav");
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.Label)] = "Pick audio",
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this,
                filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.Equal("/tmp/interview.wav", selectedFile);
        Assert.Contains("Pick audio", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_WhenPickerThrows_ShowsSelectionError()
    {
        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => throw new InvalidOperationException("picker unavailable");
        var rendered = await context.RenderAsync<DropZone>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
            "browse files button");

        Assert.Contains("File picker failed: picker unavailable", rendered.TextContent);
    }

    [Fact]
    public async Task ReadyView_ShowsExpectedLayout()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Ready);

        var rendered = await context.RenderAsync<ReadyView>();

        Assert.Contains("Audio Transcription", rendered.TextContent);
        Assert.Contains("Drop your M4A files here to convert speech into text", rendered.TextContent);
        Assert.Contains("No files added yet", rendered.TextContent);
    }

    private static string WriteSingleFileConfig(string repositoryRoot, string tempDir, string inputPath)
    {
        var rootConfigPath = Path.Combine(repositoryRoot, "appsettings.json");
        var root = JsonNode.Parse(File.ReadAllText(rootConfigPath))?.AsObject()
            ?? throw new InvalidOperationException("Failed to parse root appsettings.json");

        var transcription = root["transcription"]?.AsObject()
            ?? throw new InvalidOperationException("Root configuration is missing the transcription section.");

        var outputBaseName = Path.GetFileNameWithoutExtension(inputPath);
        transcription["processingMode"] = "single";
        transcription["inputFilePath"] = inputPath;
        transcription["wavFilePath"] = Path.Combine(tempDir, $"{outputBaseName}.wav");
        transcription["resultFilePath"] = Path.Combine(tempDir, $"{outputBaseName}.txt");
        transcription["modelFilePath"] = Path.Combine(repositoryRoot, "models", "ggml-base.bin");
        transcription["ffmpegExecutablePath"] = "ffmpeg";

        var startupValidation = transcription["startupValidation"]?.AsObject()
            ?? throw new InvalidOperationException("Root configuration is missing startupValidation.");
        startupValidation["checkInputFile"] = false;
        startupValidation["checkOutputDirectories"] = true;
        startupValidation["checkOutputWriteAccess"] = true;
        startupValidation["checkFfmpegAvailability"] = true;
        startupValidation["checkModelType"] = true;
        startupValidation["checkModelDirectory"] = true;
        startupValidation["checkModelLoadability"] = true;
        startupValidation["checkLanguageSupport"] = true;
        startupValidation["checkWhisperRuntime"] = true;

        var configPath = Path.Combine(tempDir, "appsettings.single.json");
        File.WriteAllText(configPath, root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        return configPath;
    }
}
