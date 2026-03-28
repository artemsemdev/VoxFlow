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

    [DesktopRealAudioTheory]
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

    [DesktopRealAudioFact]
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
                ResultFilePath: null,
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
        Assert.Contains("Select an audio file to transcribe locally on this Mac", rendered.TextContent);
        Assert.Contains("No file selected", rendered.TextContent);
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
            static () => Task.FromResult<string?>("/tmp/long-recording.m4a");

        var rendered = await context.RenderAsync<Routes>();
        Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);

        // Start transcription (will block on tcs) — fire and forget
        var transcribeTask = Task.Run(async () =>
        {
            await rendered.ClickAsync(
                element => element.Name == "button" && element.TextContent == "+ Browse Files",
                "browse files button");
        });

        // Wait until the ViewModel enters Running state
        var timeout = Task.Delay(TimeSpan.FromSeconds(5));
        while (context.ViewModel.CurrentState != AppState.Running)
        {
            if (timeout.IsCompleted) throw new TimeoutException("ViewModel did not enter Running state.");
            await Task.Delay(10);
        }

        Assert.Equal(AppState.Running, context.ViewModel.CurrentState);

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
            static () => Task.FromResult<string?>("/tmp/keyboard-test.wav");
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

        Assert.Equal("/tmp/keyboard-test.wav", selectedFile);
    }

    [Fact]
    public async Task DropZone_KeyboardSpace_InvokesBrowse()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/space-key.wav");
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

        Assert.Equal("/tmp/space-key.wav", selectedFile);
    }

    [Fact]
    public async Task DropZone_KeyboardOtherKey_DoesNotInvokeBrowse()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/should-not-select.wav");
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
    public async Task CompleteView_OpenFolder_InvokesLauncherWithCorrectDirectory()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Complete,
            transcriptionResult: new TranscribeFileResult(
                Success: true,
                DetectedLanguage: "en",
                ResultFilePath: "/tmp/output/result.txt",
                AcceptedSegmentCount: 5,
                SkippedSegmentCount: 0,
                Duration: TimeSpan.FromSeconds(10),
                Warnings: [],
                TranscriptPreview: "Some text"));

        var rendered = await context.RenderAsync<CompleteView>();

        await rendered.ClickAsync(
            element => element.Name == "button" && element.TextContent == "Open Folder",
            "open folder button");

        var launcher = Launcher.Default;
        var opened = Assert.Single(launcher.OpenedTargets);
        Assert.Equal("/tmp/output", opened);
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
            element => element.Name == "button" && element.TextContent == "+ Browse Files",
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
    public async Task RunningView_WithNoProgress_ShowsSpinnerAndNoBars()
    {
        await using var context = DesktopUiTestContext.Create();
        AppViewModelStateAccessor.SetState(
            context.ViewModel,
            currentState: AppState.Running,
            lastFilePath: "/tmp/audio.m4a");

        var rendered = await context.RenderAsync<RunningView>();

        // Spinner is static HTML rendered as a Markup frame, so verify via TextContent
        Assert.Contains("spinner", rendered.TextContent);
        Assert.DoesNotContain("Elapsed Time", rendered.TextContent);
        Assert.DoesNotContain("Language:", rendered.TextContent);
        // No progress bar elements should exist
        Assert.Empty(rendered.FindElements(
            element => element.Name == "div" && element.HasClass("progress-bar")));
    }

    [Fact]
    public async Task RunningView_ValidatingStage_ShowsStageWithoutLanguage()
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

        Assert.Contains("Validating", rendered.TextContent);
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
                95,
                TimeSpan.FromSeconds(60),
                "Writing result file",
                null));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("Writing", rendered.TextContent);
        Assert.Contains("Writing result file", rendered.TextContent);
        Assert.Contains("1:00", rendered.TextContent);
        Assert.DoesNotContain("Language:", rendered.TextContent);

        var progressBar = rendered.FindElement(
            element => element.Name == "div" && element.HasClass("progress-bar"),
            "progress bar");

        Assert.Contains("95%", progressBar.Attributes["style"]?.ToString());
    }

    [Fact]
    public async Task DropZone_WhenDisabled_ClickDoesNothing()
    {
        string? selectedFile = null;

        await using var context = DesktopUiTestContext.Create();
        VoxFlow.Desktop.Platform.MacFilePicker.PickAudioFileAsyncHandler =
            static () => Task.FromResult<string?>("/tmp/should-not-select.wav");
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

        Assert.Contains("Select an audio file to transcribe locally on this Mac", rendered.TextContent);
        Assert.Contains("Supported formats: M4A, WAV, MP3, AAC, FLAC, OGG, AIFF, MP4", rendered.TextContent);
        Assert.DoesNotContain("upload", rendered.TextContent, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("multiple files", rendered.TextContent, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Drop your M4A files", rendered.TextContent);
    }

    [Fact]
    public async Task DropZone_ShowsCorrectedCopy_NoM4AOnly()
    {
        await using var context = DesktopUiTestContext.Create();
        var rendered = await context.RenderAsync<DropZone>();

        Assert.Contains("Choose an audio file to transcribe", rendered.TextContent);
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
            lastFilePath: "/tmp/audio.m4a");

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
                67,
                TimeSpan.FromSeconds(30),
                "Processing segments"));

        var rendered = await context.RenderAsync<RunningView>();

        Assert.Contains("67%", rendered.TextContent);
    }

    [Fact]
    public async Task RunningView_WithLoadingModel_ShowsHumanReadableLabel()
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

        Assert.Contains("Loading model", rendered.TextContent);
        Assert.DoesNotContain("LoadingModel", rendered.TextContent);
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
                50,
                TimeSpan.FromSeconds(10),
                "Half done"));

        var rendered = await context.RenderAsync<RunningView>();

        var progressTrack = rendered.FindElement(
            element => element.Name == "div" && element.HasClass("progress-track")
                       && element.Attributes.ContainsKey("role"),
            "progress track with role");

        Assert.Equal("progressbar", progressTrack.Attributes["role"]?.ToString());
        Assert.Equal("50", progressTrack.Attributes["aria-valuenow"]?.ToString());
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
                ResultFilePath: "/tmp/result.txt",
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
            element => element.Name == "button" && element.TextContent == "Open Folder",
            "open folder button");

        var launcher = Launcher.Default;
        Assert.Empty(launcher.OpenedTargets);
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
            element => element.Name == "button" && element.TextContent == "Copy Text",
            "copy text button");

        Assert.Empty(context.JsRuntime.Invocations);
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
