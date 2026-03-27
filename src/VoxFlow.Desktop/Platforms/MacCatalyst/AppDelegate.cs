using Foundation;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop;

[Register("AppDelegate")]
public class AppDelegate : MauiUIApplicationDelegate
{
    protected override MauiApp CreateMauiApp()
    {
        try
        {
            return MauiProgram.CreateMauiApp();
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("AppDelegate.CreateMauiApp", ex);
            throw;
        }
    }
}
