using System.Text.Json.Nodes;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal static class DesktopUiTestConfigFactory
{
    public static JsonObject CreateValidSingleFileOverride(ScenarioArtifacts artifacts)
    {
        return new JsonObject
        {
            ["transcription"] = new JsonObject
            {
                ["processingMode"] = "single",
                ["wavFilePath"] = artifacts.WavOutputPath,
                ["resultFilePath"] = artifacts.ResultOutputPath,
                ["modelFilePath"] = RepositoryLayout.ModelFile,
                ["ffmpegExecutablePath"] = "ffmpeg",
                ["supportedLanguages"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["code"] = "en",
                        ["displayName"] = "English"
                    }
                },
                ["startupValidation"] = new JsonObject
                {
                    ["enabled"] = true,
                    ["printDetailedReport"] = true,
                    ["checkInputFile"] = false,
                    ["checkOutputDirectories"] = true,
                    ["checkOutputWriteAccess"] = true,
                    ["checkFfmpegAvailability"] = true,
                    ["checkModelType"] = true,
                    ["checkModelDirectory"] = true,
                    ["checkModelLoadability"] = true,
                    ["checkLanguageSupport"] = false,
                    ["checkWhisperRuntime"] = false
                }
            }
        };
    }
}
