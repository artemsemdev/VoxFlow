using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Desktop.Configuration;
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
        builder.Services.AddSingleton<IConfigurationService, DesktopConfigurationService>();
        builder.Services.AddSingleton<AppViewModel>();
        builder.Services.AddSingleton<SettingsViewModel>();
        builder.Services.AddSingleton<MainPage>();

        return builder.Build();
    }
}
