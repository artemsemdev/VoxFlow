using VoxFlow.Core.Models;
using VoxFlow.Desktop.ViewModels;

namespace VoxFlow.Desktop.Services;

public sealed class BlazorProgressHandler : IProgress<ProgressUpdate>
{
    private readonly AppViewModel _viewModel;

    public BlazorProgressHandler(AppViewModel viewModel)
    {
        _viewModel = viewModel;
    }

    public void Report(ProgressUpdate value)
    {
        _viewModel.CurrentProgress = value;
        _viewModel.NotifyStateChanged();
    }
}
