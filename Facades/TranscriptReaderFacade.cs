#nullable enable
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Reads transcript files within the allowed path policy.
/// </summary>
internal sealed class TranscriptReaderFacade : ITranscriptReaderFacade
{
    private readonly IPathPolicy pathPolicy;

    public TranscriptReaderFacade(IPathPolicy pathPolicy)
    {
        this.pathPolicy = pathPolicy;
    }

    public async Task<TranscriptReadResultDto> ReadTranscriptAsync(
        string path,
        int? maxCharacters = null,
        CancellationToken cancellationToken = default)
    {
        pathPolicy.ValidateInputPath(path);

        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Transcript file not found.", path);
        }

        var fullContent = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        var totalLength = fullContent.Length;
        var wasTruncated = false;

        if (maxCharacters.HasValue && maxCharacters.Value > 0 && fullContent.Length > maxCharacters.Value)
        {
            fullContent = fullContent[..maxCharacters.Value];
            wasTruncated = true;
        }

        return new TranscriptReadResultDto(
            Path: path,
            Content: fullContent,
            TotalLength: totalLength,
            WasTruncated: wasTruncated);
    }
}
