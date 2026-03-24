using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IValidationService
{
    Task<ValidationResult> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default);
}
