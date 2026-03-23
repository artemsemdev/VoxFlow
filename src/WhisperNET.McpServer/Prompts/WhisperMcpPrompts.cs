#nullable enable
using System.ComponentModel;
using ModelContextProtocol.Server;

namespace WhisperNET.McpServer.Prompts;

/// <summary>
/// MCP prompts that provide guided workflows for AI clients using VoxFlow.
/// </summary>
[McpServerPromptType]
internal sealed class WhisperMcpPrompts
{
    [McpServerPrompt(Name = "transcribe-local-audio")]
    [Description("Guide through transcribing a single local audio file. Asks for the audio file path and desired output location.")]
    public static string TranscribeLocalAudio(
        [Description("Absolute path to the audio file to transcribe.")]
        string audioPath,
        [Description("Optional absolute path for the output transcript file.")]
        string? outputPath = null)
    {
        var outputNote = string.IsNullOrWhiteSpace(outputPath)
            ? "The output will be written to the default configured location."
            : $"The transcript will be written to: {outputPath}";

        return $"""
            Please transcribe the following local audio file using VoxFlow:

            Audio file: {audioPath}
            {outputNote}

            Steps:
            1. First, run validate_environment to ensure the transcription environment is ready.
            2. Then, run transcribe_file with the audio path.
            3. After transcription completes, you can use read_transcript to inspect the result.

            If validation fails, check the diagnostics and suggest fixes before proceeding.
            """;
    }

    [McpServerPrompt(Name = "batch-transcribe-folder")]
    [Description("Guide through batch transcribing all audio files in a folder.")]
    public static string BatchTranscribeFolder(
        [Description("Absolute path to the folder containing audio files.")]
        string folderPath,
        [Description("Absolute path to the output directory for transcripts.")]
        string outputDirectory)
    {
        return $"""
            Please batch transcribe all audio files in the following directory:

            Input directory: {folderPath}
            Output directory: {outputDirectory}

            Steps:
            1. Run validate_environment to ensure the transcription environment is ready.
            2. Run get_supported_languages to confirm language configuration.
            3. Run transcribe_batch with the input and output directories.
            4. Review the batch results for any failures.
            5. Optionally use read_transcript to inspect individual results.

            Note: Batch transcription processes files sequentially. Large batches may take significant time.
            """;
    }

    [McpServerPrompt(Name = "diagnose-transcription-setup")]
    [Description("Diagnose the VoxFlow transcription environment and suggest fixes for any issues.")]
    public static string DiagnoseTranscriptionSetup()
    {
        return """
            Please diagnose the VoxFlow transcription environment:

            1. Run validate_environment with detailed=true to check all prerequisites.
            2. Run inspect_model to check the Whisper model status.
            3. Run get_supported_languages to verify language configuration.

            For each issue found:
            - Explain what the issue is
            - Suggest a specific fix
            - Indicate the severity (critical vs. warning)

            Common issues to check:
            - ffmpeg not installed or not on PATH
            - Whisper model missing or corrupt (needs download)
            - Output directories not writable
            - Invalid language configuration
            """;
    }

    [McpServerPrompt(Name = "inspect-last-transcript")]
    [Description("Help review a generated transcript file.")]
    public static string InspectLastTranscript(
        [Description("Absolute path to the transcript file to review.")]
        string transcriptPath)
    {
        return $"""
            Please review the following transcript file:

            Transcript path: {transcriptPath}

            Steps:
            1. Use read_transcript to load the transcript content.
            2. Summarize the key points from the transcript.
            3. Note the total length and time coverage.
            4. Flag any obvious issues (very short transcript, missing segments, etc.).
            """;
    }
}
