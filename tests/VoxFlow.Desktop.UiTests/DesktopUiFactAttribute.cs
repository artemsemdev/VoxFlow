using Xunit;

namespace VoxFlow.Desktop.UiTests;

internal sealed class DesktopUiFactAttribute : FactAttribute
{
    public DesktopUiFactAttribute()
    {
        if (!OperatingSystem.IsMacOS())
        {
            Skip = "Real macOS desktop UI automation tests require macOS.";
            return;
        }

        if (!string.Equals(Environment.GetEnvironmentVariable("VOXFLOW_RUN_DESKTOP_UI_TESTS"), "1", StringComparison.Ordinal))
        {
            Skip = "Set VOXFLOW_RUN_DESKTOP_UI_TESTS=1 to run real macOS desktop UI automation tests.";
        }
    }
}
