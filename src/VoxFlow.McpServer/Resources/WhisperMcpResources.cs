#nullable enable
using System.ComponentModel;
using System.Text.Json;
using ModelContextProtocol.Server;
using VoxFlow.Core.Interfaces;

namespace VoxFlow.McpServer.Resources;

/// <summary>
/// MCP tools that expose read-only VoxFlow context as inspection tools.
/// These act as resource-like tools that return configuration and status information.
/// </summary>
[McpServerToolType]
internal sealed class WhisperMcpResourceTools
{
    private readonly IConfigurationService configurationService;

    public WhisperMcpResourceTools(IConfigurationService configurationService)
    {
        this.configurationService = configurationService;
    }

    [McpServerTool(Name = "get_effective_config")]
    [Description("Return the resolved effective configuration snapshot currently in use by VoxFlow. Safe, read-only, and idempotent.")]
    public async Task<string> GetEffectiveConfigurationAsync()
    {
        try
        {
            var options = await configurationService.LoadAsync().ConfigureAwait(false);
            var config = new
            {
                configurationPath = options.ConfigurationPath,
                isBatchMode = options.IsBatchMode,
                modelFilePath = options.ModelFilePath,
                modelType = options.ModelType,
                ffmpegExecutablePath = options.FfmpegExecutablePath,
                outputSampleRate = options.OutputSampleRate,
                outputChannelCount = options.OutputChannelCount,
                supportedLanguages = options.GetSupportedLanguageSummary(),
                minSegmentProbability = options.MinSegmentProbability,
                useNoContext = options.UseNoContext,
                noSpeechThreshold = options.NoSpeechThreshold,
                logProbThreshold = options.LogProbThreshold,
                entropyThreshold = options.EntropyThreshold,
                startupValidationEnabled = options.StartupValidation.Enabled,
                consoleProgressEnabled = options.ConsoleProgress.Enabled
            };

            return JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }
}
