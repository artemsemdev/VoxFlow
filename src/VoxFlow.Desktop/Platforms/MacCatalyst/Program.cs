using ObjCRuntime;
using UIKit;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop;

public class Program
{
    static void Main(string[] args)
    {
        DesktopDiagnostics.InitializeUnhandledExceptionLogging();
        DesktopDiagnostics.LogInfo("Program.Main starting.");

        try
        {
            UIApplication.Main(args, null, typeof(AppDelegate));
        }
        catch (Exception ex)
        {
            DesktopDiagnostics.LogException("Program.Main", ex);
            throw;
        }
    }
}
