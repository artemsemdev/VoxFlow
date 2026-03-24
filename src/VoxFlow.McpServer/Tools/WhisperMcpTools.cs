#nullable enable
using System.ComponentModel;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ModelContextProtocol.Server;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.McpServer.Configuration;
using VoxFlow.McpServer.Security;

namespace VoxFlow.McpServer.Tools;

/// <summary>
/// MCP tools that expose VoxFlow transcription capabilities to AI clients.
/// </summary>
[McpServerToolType]
internal sealed class WhisperMcpTools
{
    private readonly ITranscriptionService transcriptionService;
    private readonly IBatchTranscriptionService batchTranscriptionService;
    private readonly IValidationService validationService;
    private readonly IModelService modelService;
    private readonly IConfigurationService configurationService;
    private readonly ITranscriptReader transcriptReader;
    private readonly IPathPolicy pathPolicy;
    private readonly McpOptions mcpOptions;

    public WhisperMcpTools(
        ITranscriptionService transcriptionService,
        IBatchTranscriptionService batchTranscriptionService,
        IValidationService validationService,
        IModelService modelService,
        IConfigurationService configurationService,
        ITranscriptReader transcriptReader,
        IPathPolicy pathPolicy,
        IOptions<McpOptions> mcpOptions)
    {
        this.transcriptionService = transcriptionService;
        this.batchTranscriptionService = batchTranscriptionService;
        this.validationService = validationService;
        this.modelService = modelService;
        this.configurationService = configurationService;
        this.transcriptReader = transcriptReader;
        this.pathPolicy = pathPolicy;
        this.mcpOptions = mcpOptions.Value;
    }

    [McpServerTool(Name = "validate_environment")]
    [Description("Run startup validation and return structured diagnostic results. This checks ffmpeg availability, model status, language support, and path configuration. Safe, read-only, and idempotent.")]
    public async Task<string> ValidateEnvironmentAsync(
        [Description("Optional absolute path to a configuration file. Uses default appsettings.json if omitted.")]
        string? configurationPath = null,
        CancellationToken cancellationToken = default)
    {
        var options = await configurationService.LoadAsync(configurationPath).ConfigureAwait(false);
        var result = await validationService.ValidateAsync(options, cancellationToken).ConfigureAwait(false);

        return JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
    }

    [McpServerTool(Name = "transcribe_file")]
    [Description("Transcribe a single local audio file using the VoxFlow Whisper pipeline. Writes a timestamped transcript to the specified output path. Requires the input file to be under allowed input roots.")]
    public async Task<string> TranscribeFileAsync(
        [Description("Absolute path to a local audio file under allowed input roots.")]
        string inputPath,
        [Description("Optional absolute path for the resulting transcript file under allowed output roots. Uses configured default if omitted.")]
        string? resultFilePath = null,
        [Description("Optional absolute path to a configuration file.")]
        string? configurationPath = null,
        CancellationToken cancellationToken = default)
    {
        // Validate paths.
        if (string.IsNullOrWhiteSpace(inputPath))
        {
            return JsonSerializer.Serialize(new { error = "inputPath is required." });
        }

        try
        {
            pathPolicy.ValidateInputPath(inputPath);
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = $"Input path validation failed: {ex.Message}" });
        }

        if (!string.IsNullOrWhiteSpace(resultFilePath))
        {
            try
            {
                pathPolicy.ValidateOutputPath(resultFilePath);
            }
            catch (Exception ex)
            {
                return JsonSerializer.Serialize(new { error = $"Output path validation failed: {ex.Message}" });
            }
        }

        var request = new TranscribeFileRequest(
            InputPath: inputPath,
            ResultFilePath: resultFilePath,
            ConfigurationPath: configurationPath);

        var result = await transcriptionService.TranscribeFileAsync(request, cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        return JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
    }

    [McpServerTool(Name = "transcribe_batch")]
    [Description("Run batch transcription over a directory of audio files. Requires batch mode to be enabled in MCP configuration. Each file produces its own transcript.")]
    public async Task<string> TranscribeBatchAsync(
        [Description("Absolute path to the input directory containing audio files.")]
        string inputDirectory,
        [Description("Absolute path to the output directory for transcript files.")]
        string outputDirectory,
        [Description("Optional file pattern for matching input files. Defaults to '*.m4a'.")]
        string? filePattern = null,
        [Description("Optional path for the batch summary report file.")]
        string? summaryFilePath = null,
        [Description("Stop the entire batch on the first file failure. Defaults to false.")]
        bool stopOnFirstError = false,
        [Description("Optional absolute path to a configuration file.")]
        string? configurationPath = null,
        CancellationToken cancellationToken = default)
    {
        if (!mcpOptions.AllowBatch)
        {
            return JsonSerializer.Serialize(new { error = "Batch transcription is disabled in MCP configuration." });
        }

        // Validate paths.
        if (string.IsNullOrWhiteSpace(inputDirectory))
        {
            return JsonSerializer.Serialize(new { error = "inputDirectory is required." });
        }

        if (string.IsNullOrWhiteSpace(outputDirectory))
        {
            return JsonSerializer.Serialize(new { error = "outputDirectory is required." });
        }

        try
        {
            pathPolicy.ValidateInputPath(inputDirectory);
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = $"Input directory validation failed: {ex.Message}" });
        }

        try
        {
            pathPolicy.ValidateOutputPath(outputDirectory);
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = $"Output directory validation failed: {ex.Message}" });
        }

        var request = new BatchTranscribeRequest(
            InputDirectory: inputDirectory,
            OutputDirectory: outputDirectory,
            FilePattern: filePattern,
            SummaryFilePath: summaryFilePath,
            StopOnFirstError: stopOnFirstError,
            ConfigurationPath: configurationPath,
            MaxFiles: mcpOptions.MaxBatchFiles);

        var result = await batchTranscriptionService.TranscribeBatchAsync(request, cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        return JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
    }

    [McpServerTool(Name = "get_supported_languages")]
    [Description("Return the list of supported languages from the current configuration. Safe, read-only, and fast.")]
    public string GetSupportedLanguages(
        [Description("Optional absolute path to a configuration file.")]
        string? configurationPath = null)
    {
        try
        {
            var languages = configurationService.GetSupportedLanguages(configurationPath);
            return JsonSerializer.Serialize(languages, new JsonSerializerOptions { WriteIndented = true });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool(Name = "inspect_model")]
    [Description("Return structured information about the configured Whisper model: path, type, file size, whether it exists and is loadable, whether it needs downloading. Safe, read-only.")]
    public async Task<string> InspectModelAsync(
        [Description("Optional absolute path to a configuration file.")]
        string? configurationPath = null)
    {
        try
        {
            var options = await configurationService.LoadAsync(configurationPath).ConfigureAwait(false);
            var result = modelService.InspectModel(options);
            return JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }

    [McpServerTool(Name = "read_transcript")]
    [Description("Read a previously produced transcript file. The file must be under allowed output roots. Useful for inspecting transcription results after tool execution.")]
    public async Task<string> ReadTranscriptAsync(
        [Description("Absolute path to the transcript file to read.")]
        string path,
        [Description("Optional maximum number of characters to return. Returns the full content if omitted.")]
        int? maxCharacters = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return JsonSerializer.Serialize(new { error = "path is required." });
        }

        try
        {
            pathPolicy.ValidateInputPath(path);
            var result = await transcriptReader.ReadAsync(path, maxCharacters, cancellationToken)
                .ConfigureAwait(false);
            return JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
        }
        catch (UnauthorizedAccessException ex)
        {
            return JsonSerializer.Serialize(new { error = $"Access denied: {ex.Message}" });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }
}
