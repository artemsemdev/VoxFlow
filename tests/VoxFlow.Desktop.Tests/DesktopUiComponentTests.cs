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
    // Hardcoded POSIX-style paths are non-portable (Windows lacks them). Path.GetTempPath()
    // resolves to the platform's temp directory at runtime — these helper paths are passed
    // to mocked services that don't actually touch the filesystem; the helpers exist purely
    // so assertions and stub data stay platform-agnostic.
    private static string FakeAudioPath(string fileName) => Path.Combine(Path.GetTempPath(), fileName);

    private static string FakeResultPath(string fileName) => FakeAudioPath(fileName);

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
                45,
                TimeSpan.FromSeconds(125),
                "Processing audio",
                "English"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("audio file", rendered.TextContent);
        Assert.Contains("Processing audio", rendered.TextContent);
        // Transcribing at 45% overall → Transcription-local 50% (banding 0..90)
        Assert.Contains("50", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_BrowseFile_WithStubTranscription_CompletesViaRealClick()
    {
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(
                success: true,
                path: FakeResultPath($"{Path.GetFileNameWithoutExtension(request.InputPath)}.txt"))));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("interview.m4a"));

        var rendered = await context.RenderAsync<Routes>();
        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.Contains("Audio Transcription", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        var delegateTranscriptionService = Assert.IsType<DelegateTranscriptionService>(context.TranscriptionService);
        Assert.Equal(FakeAudioPath("interview.m4a"), delegateTranscriptionService.LastFilePath);
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
            element => element.Name == "button" && element.TextContent == "Choose File",
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
            static () => Task.FromResult<string?>(FakeAudioPath("demo.m4a"));
        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
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
                : TestTranscriptionFactory.Create(success: true, path: FakeResultPath($"{Path.GetFileNameWithoutExtension(request.InputPath)}.txt"))));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("demo.wav"));
        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        Assert.Equal(AppState.Failed, context.ViewModel.CurrentState);
        Assert.Contains("Transcription Failed", rendered.TextContent);
        Assert.Contains("retry me", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Retry",
            "failed retry button");

        var delegateTranscriptionService = Assert.IsType<DelegateTranscriptionService>(context.TranscriptionService);
        Assert.Equal(2, attempts);
        Assert.Equal(FakeAudioPath("demo.wav"), delegateTranscriptionService.LastFilePath);
        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.NotNull(context.ViewModel.TranscriptionResult);
        Assert.True(context.ViewModel.TranscriptionResult!.Success);
        Assert.Contains("demo.wav", rendered.TextContent);
    }

    [DesktopRealAudioTheory]
    [InlineData("Test 1.m4a")]
    [InlineData("Test 2.m4a")]
    public async Task Routes_BrowseFile_WithRealAudio_CompletesTranscription(string fileName)
    {
        var repositoryRoot = Path.GetDirectoryName(ViewModelFactory.ResolveRootSettingsPath())
            ?? throw new InvalidOperationException("Could not resolve repository root.");
        var inputPath = TestFixtureLocator.Resolve(fileName);
        Assert.True(File.Exists(inputPath), TestFixtureLocator.FormatMissingFixtureReason(inputPath));

        // TemporaryDirectory.Dispose handles recursive delete on exit, so the test
        // body no longer needs a try/finally + bare catch for cleanup.
        using var tempDir = new TemporaryDirectory();
        var configPath = WriteSingleFileConfig(repositoryRoot, tempDir.Path, inputPath);
        await using var context = DesktopUiTestContext.CreateWithRealCore(configPath);

        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            () => Task.FromResult<string?>(inputPath);

        var rendered = await context.RenderAsync<Routes>();
        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        var resultFilePath = Path.Combine(tempDir.Path, $"{Path.GetFileNameWithoutExtension(fileName)}.txt");

        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.NotNull(context.ViewModel.TranscriptionResult);
        Assert.True(context.ViewModel.TranscriptionResult!.Success);
        Assert.Equal(resultFilePath, context.ViewModel.TranscriptionResult.ResultFilePath);
        Assert.True(File.Exists(resultFilePath), $"Expected result file to exist: {resultFilePath}");
        Assert.Contains(Path.GetFileName(inputPath), rendered.TextContent);
    }

    [DesktopRealAudioFact]
    public async Task ReadyView_BrowseFile_WithRealAudio_CompletesTranscription()
    {
        var repositoryRoot = Path.GetDirectoryName(ViewModelFactory.ResolveRootSettingsPath())
            ?? throw new InvalidOperationException("Could not resolve repository root.");
        var inputPath = TestFixtureLocator.Resolve("Test 1.m4a");
        Assert.True(File.Exists(inputPath), TestFixtureLocator.FormatMissingFixtureReason(inputPath));

        using var tempDir = new TemporaryDirectory();
        var configPath = WriteSingleFileConfig(repositoryRoot, tempDir.Path, inputPath);
        await using var context = DesktopUiTestContext.CreateWithRealCore(configPath);

        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            () => Task.FromResult<string?>(inputPath);

        var rendered = await context.RenderAsync<ReadyView>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        var resultFilePath = Path.Combine(tempDir.Path, "Test 1.txt");

        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.NotNull(context.ViewModel.TranscriptionResult);
        Assert.True(context.ViewModel.TranscriptionResult!.Success);
        Assert.Equal(resultFilePath, context.ViewModel.TranscriptionResult.ResultFilePath);
        Assert.True(File.Exists(resultFilePath), $"Expected result file to exist: {resultFilePath}");
    }

    [Fact]
    public async Task CompleteView_CopyText_UsesResultActionService_AndUpdatesButton()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: null,
                AcceptedSegmentCount: 7,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(12),
                Warnings: [],
                TranscriptPreview: "Clipboard text"));

        var rendered = await context.RenderAsync<CompleteView>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent.Contains("Copy Text"),
            "copy text button");

        Assert.Equal(["Clipboard text"], context.ResultActionService.CopiedTexts);
        Assert.Contains("Copied!", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_WhenTranscriptionCompletes_BackButton_ReturnsToReady()
    {
        var transcriptionService = new DelegateTranscriptionService((request, _, _) =>
            Task.FromResult(TestTranscriptionFactory.Create(
                success: true,
                path: FakeResultPath($"{Path.GetFileNameWithoutExtension(request.InputPath)}.txt"))));

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("meeting_01.m4a"));

        var rendered = await context.RenderAsync<Routes>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        Assert.Equal(AppState.Complete, context.ViewModel.CurrentState);
        Assert.Contains("meeting_01.m4a", rendered.TextContent);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.HasClass("complete-new-btn"),
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
            static () => Task.FromResult<string?>(FakeAudioPath("interview.wav"));
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.Label)] = "Pick audio",
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this,
                filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        Assert.Equal(FakeAudioPath("interview.wav"), selectedFile);
        Assert.Contains("Drop audio file here", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_OnFirstRender_InitializesJsDropZone()
    {
        await using var context = DesktopUiTestContext.Create();

        _ = await context.RenderAsync<DropZone>();

        var invocation = Assert.Single(context.JsRuntime.Invocations, call => call.Identifier == "voxFlowInterop.initDropZone");
        Assert.Equal("file-drop-zone", invocation.Arguments[0]);
        Assert.Equal("file-drop-zone-input", invocation.Arguments[1]);
    }

    [Fact]
    public async Task DropZone_WhenPickerThrows_ShowsSelectionError()
    {
        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => throw new InvalidOperationException("picker unavailable");
        var rendered = await context.RenderAsync<DropZone>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
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
        Assert.Contains("M4A · WAV · MP3 · AAC · FLAC · OGG · AIFF · MP4", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_CancelDuringTranscription_ReturnsToReady()
    {
        var tcs = new TaskCompletionSource<TranscribeFileResult>();
        var transcriptionService = new DelegateTranscriptionService((_, _, ct) =>
        {
            ct.Register(() => tcs.TrySetCanceled(ct));
            return tcs.Task;
        });

        await using var context = DesktopUiTestContext.Create(transcriptionService: transcriptionService);
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("long-recording.m4a"));

        var rendered = await context.RenderAsync<Routes>();
        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);

        // Start transcription (will block on tcs) — fire and forget
        var transcribeTask = Task.Run(async () =>
        {
            await rendered.ClickAsync(
                element => element.Name == "button" && element.TextContent == "Choose File",
                "browse files button");
        });

        // Wait until the ViewModel enters Running state. WaitForCondition replaces the
        // ad-hoc polling loop the test had before; the helper polls at 10 ms with a 5 s
        // cap and surfaces a clear failure if the predicate never holds.
        var becameRunning = await WaitForCondition.WaitForAsync(
            () => context.ViewModel.CurrentState == AppState.Running);
        Assert.True(becameRunning, "ViewModel did not enter Running state within 5 s.");

        // Click Cancel
        context.ViewModel.CancelTranscription();

        await transcribeTask;
        await rendered.SynchronizeAsync();

        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.Contains("Audio Transcription", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_KeyboardEnter_InvokesBrowse()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("keyboard-test.wav"));
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this, filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.KeyDownAsync(
            element => element.Name == "div" && element.Attributes.ContainsKey("id")
                       && element.Attributes["id"]?.ToString() == "file-drop-zone",
            "drop zone div",
            "Enter");

        Assert.Equal(FakeAudioPath("keyboard-test.wav"), selectedFile);
    }

    [Fact]
    public async Task DropZone_KeyboardSpace_InvokesBrowse()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("space-key.wav"));
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this, filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.KeyDownAsync(
            element => element.Name == "div" && element.Attributes.ContainsKey("id")
                       && element.Attributes["id"]?.ToString() == "file-drop-zone",
            "drop zone div",
            " ");

        Assert.Equal(FakeAudioPath("space-key.wav"), selectedFile);
    }

    [Fact]
    public async Task DropZone_KeyboardOtherKey_DoesNotInvokeBrowse()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("should-not-select.wav"));
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this, filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.KeyDownAsync(
            element => element.Name == "div" && element.Attributes.ContainsKey("id")
                       && element.Attributes["id"]?.ToString() == "file-drop-zone",
            "drop zone div",
            "Tab");

        Assert.Null(selectedFile);
    }

    [Fact]
    public async Task CompleteView_OpenFolder_UsesResultActionService_WithResultPath()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: Path.Combine(Path.GetTempPath(), "output", "result.txt"),
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(10),
                Warnings: [],
                TranscriptPreview: "Some text"));

        var rendered = await context.RenderAsync<CompleteView>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent.Contains("Open Folder"),
            "open folder button");

        Assert.Equal([Path.Combine(Path.GetTempPath(), "output", "result.txt")], context.ResultActionService.OpenedResultPaths);
    }

    [Fact]
    public async Task DropZone_WhenPickerReturnsNull_NoErrorShown_StateUnchanged()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(null);
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this, filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Choose File",
            "browse files button");

        Assert.Null(selectedFile);
        Assert.DoesNotContain("File picker failed", rendered.TextContent);
    }

    [Fact]
    public async Task Routes_WhenStartupRetryFailsAgain_StillShowsError()
    {
        var configurationService = new DelegateConfigurationService(_ =>
            throw new InvalidOperationException("persistent config error"));

        await using var context = DesktopUiTestContext.Create(configurationService: configurationService);
        var rendered = await context.RenderAsync<Routes>();

        Assert.Contains("Startup Failed", rendered.TextContent);
        Assert.Contains("persistent config error", rendered.TextContent);

        // Click Retry — should still fail
        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Retry",
            "startup retry button");

        Assert.Contains("Startup Failed", rendered.TextContent);
        Assert.Contains("persistent config error", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WithNoProgress_ShowsStartingLabelAndSpinner()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            lastFilePath: FakeAudioPath("audio.m4a"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Starting transcription", rendered.TextContent);
        Assert.DoesNotContain("Elapsed Time", rendered.TextContent);
        Assert.DoesNotContain("Language:", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_ValidatingStage_ShowsMessageWithoutLanguage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Validating,
                10,
                TimeSpan.FromSeconds(3),
                "Checking input file",
                null));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Checking input file", rendered.TextContent);
        Assert.DoesNotContain("Language:", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WritingStage_ShowsCorrectStage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Writing,
                97,
                TimeSpan.FromSeconds(60),
                "Writing result file",
                null));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Writing result file", rendered.TextContent);
        // Writing at 97% overall → Merge-local 40% (banding 95..100)
        Assert.Contains("40", rendered.TextContent);
        Assert.DoesNotContain("Language:", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_WhenDisabled_ClickDoesNothing()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>(FakeAudioPath("should-not-select.wav"));
        var parameters = ParameterView.FromDictionary(new Dictionary<string, object?>
        {
            [nameof(DropZone.IsDisabled)] = true,
            [nameof(DropZone.OnFileSelected)] = EventCallback.Factory.Create<string>(
                this, filePath => selectedFile = filePath)
        });

        var rendered = await context.RenderAsync<DropZone>(parameters);

        // Click the drop zone div itself (not the button)
        await rendered.ClickAsync(
            element => element.Name == "div" && element.Attributes.ContainsKey("id")
                       && element.Attributes["id"]?.ToString() == "file-drop-zone",
            "drop zone div");

        Assert.Null(selectedFile);
    }

    // -----------------------------------------------------------------------
    // B1: Phase 1 — Expanded tests for Workstream A UI contract changes
    // -----------------------------------------------------------------------

    [Fact]
    public async Task ReadyView_ShowsCorrectedCopy_NoM4AOnly_NoUpload_NoMultipleFiles()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(context.ViewModel, currentState: AppState.Ready);

        var rendered = await context.RenderAsync<ReadyView>();

        Assert.Contains("M4A · WAV · MP3 · AAC · FLAC · OGG · AIFF · MP4", rendered.TextContent);
        Assert.DoesNotContain("upload", rendered.TextContent, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("multiple files", rendered.TextContent, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Drop your M4A files", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_ShowsCorrectedCopy_NoM4AOnly()
    {
        await using var context = DesktopUiTestContext.Create();
        var rendered = await context.RenderAsync<DropZone>();

        Assert.Contains("Drop audio file here", rendered.TextContent);
        Assert.DoesNotContain("Drop your M4A files", rendered.TextContent);
        Assert.DoesNotContain("upload", rendered.TextContent, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ReadyView_ShowsNonBlockingWarnings_WhenCanStartButHasWarnings()
    {
        var validationService = new DelegateValidationService((_, _) =>
            Task.FromResult(TestValidationFactory.Create(
                canStart: true,
                new ValidationCheck("model", ValidationCheckStatus.Warning, "Using a small model; accuracy may be limited."))));

        await using var context = DesktopUiTestContext.Create(validationService: validationService);
        var rendered = await context.RenderAsync<Routes>();

        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
        Assert.True(context.ViewModel.HasWarnings);
        Assert.Contains("Using a small model", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_BeforeFirstProgress_ShowsStartingTranscription()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            lastFilePath: FakeAudioPath("audio.m4a"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Starting transcription...", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WithProgress_ShowsNumericPercent()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Transcribing,
                63,
                TimeSpan.FromSeconds(30),
                "Processing segments"));

        var rendered = await context.RenderAsync<RunningView>();

        // Transcribing at 63% overall → Transcription-local 70% (banding 0..90)
        Assert.Contains("70", rendered.TextContent);
        Assert.Contains("%", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WhenProgressChangesAfterRender_RefreshesPercentAndStage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Validating,
                0,
                TimeSpan.Zero,
                "Running CLI transcription pipeline..."));

        var rendered = await context.RenderAsync<RunningView>();

        context.ViewModel.CurrentProgress = new ProgressUpdate(
            ProgressStage.Transcribing,
            36,
            TimeSpan.FromSeconds(12),
            "Processing audio",
            "English");

        await rendered.SynchronizeAsync();

        // Transcribing at 36% overall → Transcription-local 40% (banding 0..90)
        Assert.Contains("40", rendered.TextContent);
        Assert.Contains("Processing audio", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WithLoadingModel_ShowsMessageText()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.LoadingModel,
                15,
                TimeSpan.FromSeconds(5),
                "Loading ggml-base.bin"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Loading ggml-base.bin", rendered.TextContent);
        Assert.DoesNotContain("LoadingModel", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_ActivityPanel_RendersPulseDotAndStageMessage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.LoadingModel,
                8,
                TimeSpan.FromSeconds(3),
                null));

        var rendered = await context.RenderAsync<RunningView>();

        var panel = rendered.FindElement(
            e => e.HasClass("activity-panel"),
            ".activity-panel");
        Assert.Contains("loading model", panel.TextContent, StringComparison.OrdinalIgnoreCase);

        var pulseDots = rendered.FindElements(e => e.HasClass("activity-pulse-dot"));
        Assert.Single(pulseDots);
    }

    [Fact]
    public async Task RunningView_ProgressBar_HasAccessibilityAttributes()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            currentProgress: new ProgressUpdate(
                ProgressStage.Transcribing,
                45,
                TimeSpan.FromSeconds(10),
                "Half done"));

        var rendered = await context.RenderAsync<RunningView>();

        var progressWrapper = rendered.FindElement(
            element => element.Name == "div"
                       && element.HasClass("phase-ring-stack")
                       && element.Attributes.ContainsKey("role")
                       && element.Attributes.TryGetValue("aria-label", out var label)
                       && label?.ToString() == "Transcription progress",
            "phase-ring-stack progressbar");

        Assert.Equal("progressbar", progressWrapper.Attributes["role"]?.ToString());
        // Transcribing at 45% overall → Transcription-local 50% (banding 0..90)
        Assert.Equal("50", progressWrapper.Attributes["aria-valuenow"]?.ToString());
    }

    [Fact]
    public async Task CompleteView_WhenPreviewUnavailable_ShowsUnavailableMessage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.txt"),
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: null));

        var rendered = await context.RenderAsync<CompleteView>();

        Assert.Contains("Transcript preview is not available", rendered.TextContent);
    }

    [Fact]
    public async Task CompleteView_WhenResultPathMissing_OpenFolderIsNoOp()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: null,
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: "Some text"));

        var rendered = await context.RenderAsync<CompleteView>();

        // Button is always present but gracefully does nothing when path is missing
        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent.Contains("Open Folder"),
            "open folder button");

        Assert.Empty(context.ResultActionService.OpenedResultPaths);
    }

    [Fact]
    public async Task CompleteView_WhenNoPreviewAndNoResultPath_CopyIsNoOp()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: null,
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: null));

        var rendered = await context.RenderAsync<CompleteView>();

        // Button is always present but gracefully does nothing when no text is available
        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent.Contains("Copy Text"),
            "copy text button");

        Assert.Empty(context.ResultActionService.CopiedTexts);
    }

    // -----------------------------------------------------------------------
    // P2.5 — CompleteView: SpeakerTranscriptView integration + enrichment banner
    // -----------------------------------------------------------------------

    private static TranscriptDocument MakeSpeakerDoc(params (string Speaker, double Start, double End, string Word)[] words)
    {
        var meta = new TranscriptMetadata(SchemaVersion: 1, DiarizationModel: "test", SidecarVersion: 1);
        var tokens = words
            .Select(w => new TranscriptWord(
                TimeSpan.FromSeconds(w.Start),
                TimeSpan.FromSeconds(w.End),
                w.Word,
                w.Speaker))
            .ToList();
        var turns = SpeakerTurn.GroupConsecutive(tokens);
        var roster = turns
            .Select(t => t.SpeakerId)
            .Distinct()
            .Select(id => new SpeakerInfo(id, id, TimeSpan.Zero))
            .ToList();
        return new TranscriptDocument(roster, tokens, turns, meta);
    }

    [Fact]
    public async Task CompleteView_NullDocument_RendersPlainTextPreview_Unchanged()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.txt"),
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: "Hello plain text."));

        var rendered = await context.RenderAsync<CompleteView>();

        Assert.Contains("Hello plain text.", rendered.TextContent);
        var speakerTurns = rendered.FindElements(e => e.Attributes.ContainsKey("data-speaker-label"));
        Assert.Empty(speakerTurns);
    }

    [Fact]
    public async Task CompleteView_NonNullDocument_RendersSpeakerTranscriptView_AndHidesPlainTextPreview()
    {
        await using var context = DesktopUiTestContext.Create();
        var doc = MakeSpeakerDoc(("A", 0, 1, "hi"), ("B", 1, 2, "there"));
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.voxflow.json"),
                AcceptedSegmentCount: 2,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(2),
                Warnings: [],
                TranscriptPreview: "hi there",
                SpeakerTranscript: doc));

        var rendered = await context.RenderAsync<CompleteView>();

        Assert.Contains("Speaker A", rendered.TextContent);
        Assert.Contains("Speaker B", rendered.TextContent);
        var speakerTurns = rendered.FindElements(e => e.Attributes.ContainsKey("data-speaker-label"));
        Assert.Equal(2, speakerTurns.Count);
        Assert.DoesNotContain("Transcript Preview", rendered.TextContent);
        var plainPreview = rendered.FindElements(e => e.HasClass("transcript-preview"));
        Assert.Empty(plainPreview);
    }

    [Fact]
    public async Task CompleteView_EnrichmentWarnings_RendersBanner_WithEachMessage()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.txt"),
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: "preview",
                EnrichmentWarnings: ["speaker-labeling: model load failed", "fell back to plain text"]));

        var rendered = await context.RenderAsync<CompleteView>();

        Assert.Contains("speaker-labeling: model load failed", rendered.TextContent);
        Assert.Contains("fell back to plain text", rendered.TextContent);
    }

    [Fact]
    public async Task CompleteView_EnrichmentWarnings_EmptyList_DoesNotRenderBanner()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.txt"),
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(8),
                Warnings: [],
                TranscriptPreview: "preview"));

        var rendered = await context.RenderAsync<CompleteView>();

        var banner = rendered.FindElements(e => e.HasClass("enrichment-warnings-banner"));
        Assert.Empty(banner);
    }

    [Fact]
    public async Task CompleteView_DocumentAndWarningsBoth_RendersBothSections()
    {
        await using var context = DesktopUiTestContext.Create();
        var doc = MakeSpeakerDoc(("A", 0, 1, "hi"));
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: FakeResultPath("result.voxflow.json"),
                AcceptedSegmentCount: 1,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(1),
                Warnings: [],
                TranscriptPreview: "hi",
                SpeakerTranscript: doc,
                EnrichmentWarnings: ["heads-up: partial coverage"]));

        var rendered = await context.RenderAsync<CompleteView>();

        Assert.Contains("heads-up: partial coverage", rendered.TextContent);
        Assert.Contains("Speaker A", rendered.TextContent);
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

    [Fact]
    public async Task CompleteView_RendersTopBar()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: null,
                AcceptedSegmentCount: 2,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(5),
                Warnings: [],
                TranscriptPreview: "preview"));

        var rendered = await context.RenderAsync<CompleteView>();

        var topbar = rendered.FindElement(e => e.HasClass("topbar"), ".topbar header");
        Assert.Contains("VoxFlow", topbar.TextContent);
    }

    [Fact]
    public async Task FailedView_RendersTopBar()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Failed,
            errorMessage: "Something went wrong");

        var rendered = await context.RenderAsync<FailedView>();

        var topbar = rendered.FindElement(e => e.HasClass("topbar"), ".topbar header");
        Assert.Contains("VoxFlow", topbar.TextContent);
    }
}
