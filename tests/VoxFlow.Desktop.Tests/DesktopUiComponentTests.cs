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
        Assert.Contains("Ready to Transcribe", rendered.TextContent);
    }

    [Fact]
    public async Task MainLayout_SettingsToggle_OpensSettingsPanel()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Ready,
            validationResult: TestValidationFactory.Create(canStart: true));

        var rendered = await context.RenderAsync<MainLayout>();

        Assert.DoesNotContain("Output Directory", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.HasClass("settings-toggle"),
            "settings toggle button");

        Assert.Contains("Output Directory", rendered.TextContent);
        Assert.Contains("Open appsettings.json", rendered.TextContent);
    }

    [Fact]
    public async Task NotReadyView_RendersRecoveryActions_ForFailedChecks()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.NotReady,
            validationResult: TestValidationFactory.Create(
                canStart: false,
                new ValidationCheck("ffmpeg", ValidationCheckStatus.Failed, "ffmpeg is missing."),
                new ValidationCheck("model directory", ValidationCheckStatus.Failed, "Directory not found."),
                new ValidationCheck("language support", ValidationCheckStatus.Passed, "English")));

        var rendered = await context.RenderAsync<NotReadyView>();

        Assert.Contains("Environment Setup Required", rendered.TextContent);
        Assert.Contains("Install ffmpeg", rendered.TextContent);
        Assert.Contains("Download Model", rendered.TextContent);
        Assert.Contains("Retry Validation", rendered.TextContent);
    }

    [Fact]
    public async Task StatusBar_WithoutValidation_ShowsInitializingState()
    {
        await using var context = DesktopUiTestContext.Create();

        var rendered = await context.RenderAsync<StatusBar>();

        Assert.Contains("Initializing...", rendered.TextContent);
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

        Assert.Contains("Transcribing...", rendered.TextContent);
        Assert.Contains("Processing audio", rendered.TextContent);
        Assert.Contains("Language: English", rendered.TextContent);
        Assert.Contains("2:05", rendered.TextContent);

        var progressBar = rendered.FindElement(
            element => element.Name == "div" && element.HasClass("progress-bar"),
            "progress bar");

        Assert.Contains("42%", progressBar.Attributes["style"]?.ToString());
    }

    [Fact(Skip = "Headless renderer timing for manually injected failed-state is still under investigation.")]
    public async Task FailedMainLayout_ChooseDifferentFile_Revalidates_ToReady()
    {
        var validationService = new DelegateValidationService((_, _) =>
            Task.FromResult(TestValidationFactory.Create(
                canStart: true,
                new ValidationCheck("ffmpeg", ValidationCheckStatus.Passed, "ffmpeg is available."))));

        await using var context = DesktopUiTestContext.Create(validationService: validationService);
        var rendered = await context.RenderAsync<Routes>();

        await context.Renderer.Dispatcher.InvokeAsync(() =>
        {
            AppViewModelStateAccessor.SetState(
                context.ViewModel,
                currentState: AppState.Failed,
                validationResult: TestValidationFactory.Create(canStart: true),
                errorMessage: "ffmpeg crashed");
            return Task.CompletedTask;
        });
        await rendered.SynchronizeAsync();

        Assert.Contains("Transcription Failed", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose Different File",
            "choose different file button");

        Assert.Contains("Ready to Transcribe", rendered.TextContent);
        Assert.DoesNotContain("Transcription Failed", rendered.TextContent);
    }

    [Fact(Skip = "Headless renderer timing for manually injected failed-state is still under investigation.")]
    public async Task FailedMainLayout_Retry_UsesLastFile_AndTransitions_ToComplete()
    {
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(success: true, path: $"/tmp/{Path.GetFileNameWithoutExtension(request.InputPath)}.txt")));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        var rendered = await context.RenderAsync<Routes>();

        await context.Renderer.Dispatcher.InvokeAsync(() =>
        {
            AppViewModelStateAccessor.SetState(
                context.ViewModel,
                currentState: AppState.Failed,
                validationResult: TestValidationFactory.Create(canStart: true),
                errorMessage: "retry me",
                lastFilePath: "/tmp/demo.wav");
            return Task.CompletedTask;
        });
        await rendered.SynchronizeAsync();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Retry",
            "failed retry button");

        var delegateTranscriptionService = Assert.IsType<DelegateTranscriptionService>(context.TranscriptionService);
        Assert.Equal("/tmp/demo.wav", delegateTranscriptionService.LastFilePath);
        Assert.Contains("Transcription Complete", rendered.TextContent);
        Assert.Contains("Finished in", rendered.TextContent);
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
                element => element.Name == "button" && element.TextContent == "Browse Files",
                "browse files button");

            var resultFilePath = Path.Combine(tempDir, $"{Path.GetFileNameWithoutExtension(fileName)}.txt");

            Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
            Assert.NotNull(context.ViewModel.TranscriptionResult);
            Assert.True(context.ViewModel.TranscriptionResult!.Success);
            Assert.Equal(resultFilePath, context.ViewModel.TranscriptionResult.ResultFilePath);
            Assert.True(File.Exists(resultFilePath), $"Expected result file to exist: {resultFilePath}");
            Assert.Contains("Transcription Complete", rendered.TextContent);
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
                element => element.Name == "button" && element.TextContent == "Browse Files",
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
    public async Task CompleteView_CopyTranscript_UsesClipboardInterop_AndUpdatesButton()
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
            element => element.Name == "button" && element.TextContent == "Copy Transcript",
            "copy transcript button");

        var invocation = Assert.Single(context.JsRuntime.Invocations);
        Assert.Equal("voxFlowInterop.copyToClipboard", invocation.Identifier);
        Assert.Equal("Clipboard text", Assert.Single(invocation.Arguments));
        Assert.Contains("Copied!", rendered.TextContent);
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
            element => element.Name == "button" && element.TextContent == "Browse Files",
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
            element => element.Name == "button" && element.TextContent == "Browse Files",
            "browse files button");

        Assert.Contains("File picker failed: picker unavailable", rendered.TextContent);
    }

    [Fact]
    public async Task SettingsPanel_LoadsConfiguredValues_AndSaveClosesPanel()
    {
        var options = TranscriptionOptions.LoadFromPath(ViewModelFactory.ResolveRootSettingsPath());
        var closed = false;

        await using var context = DesktopUiTestContext.Create();
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(SettingsPanel.OnClose)] = EventCallback.Factory.Create(this, () => closed = true)
        });

        var rendered = await context.RenderAsync<SettingsPanel>(parameters);

        var outputInput = rendered.FindElement(
            element => element.Name == "input" &&
                Equals(element.Attributes.GetValueOrDefault("placeholder"), "Default output directory"),
            "output directory input");
        var ffmpegInput = rendered.FindElement(
            element => element.Name == "input" &&
                Equals(element.Attributes.GetValueOrDefault("placeholder"), "/usr/local/bin/ffmpeg"),
            "ffmpeg path input");

        Assert.Equal(options.ResultFilePath, outputInput.Attributes["value"]?.ToString());
        Assert.Equal(options.FfmpegExecutablePath, ffmpegInput.Attributes["value"]?.ToString());

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Save",
            "settings save button");

        Assert.True(closed);
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
