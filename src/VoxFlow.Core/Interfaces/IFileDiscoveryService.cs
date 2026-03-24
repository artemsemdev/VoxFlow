using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IFileDiscoveryService
{
    IReadOnlyList<DiscoveredFile> DiscoverInputFiles(BatchOptions batchOptions);
}
