#nullable enable
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services;

/// <summary>
/// Reads transcript files from disk, with optional truncation support.
/// </summary>
internal sealed class TranscriptReader : ITranscriptReader
{
    /// <summary>
    /// Reads the full content of a transcript file, optionally truncating to a maximum character count.
    /// </summary>
    public async Task<TranscriptReadResult> ReadAsync(
        string path,
        int? maxCharacters = null,
        CancellationToken cancellationToken = default)
    {
        var content = await File.ReadAllTextAsync(path, cancellationToken);
        var totalLength = content.Length;
        var wasTruncated = false;

        if (maxCharacters.HasValue && content.Length > maxCharacters.Value)
        {
            content = content[..maxCharacters.Value];
            wasTruncated = true;
        }

        return new TranscriptReadResult(path, content, totalLength, wasTruncated);
    }
}
