namespace VoxFlow.Core.Models;

public sealed record ModelInfo(
    string ModelPath,
    string ModelType,
    bool Exists,
    long? FileSizeBytes,
    bool IsLoadable,
    bool NeedsDownload);
