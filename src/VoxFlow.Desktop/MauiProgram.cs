using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Desktop.Configuration;
using VoxFlow.Desktop.Services;
using VoxFlow.Desktop.ViewModels;

namespace VoxFlow.Desktop;

public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder
            .UseMauiApp<App>()
            .ConfigureFonts(fonts =>
            {
                fonts.AddFont("OpenSans-Regular.ttf", "OpenSansRegular");
            });

        builder.Services.AddMauiBlazorWebView();
        builder.Services.AddVoxFlowCore();
        builder.Services.AddSingleton<DesktopConfigurationService>();
        builder.Services.AddSingleton<IConfigurationService>(sp => sp.GetRequiredService<DesktopConfigurationService>());
        if (DesktopCliSupport.ShouldUseCliBridge())
        {
            builder.Services.AddSingleton<ITranscriptionService, DesktopCliTranscriptionService>();
        }
        builder.Services.AddSingleton<AppViewModel>();
        builder.Services.AddSingleton<MainPage>();

        return builder.Build();
    }
}
