using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services;

/// <summary>
/// Writes filtered transcript segments to the configured text output format.
/// </summary>
internal sealed class OutputWriter : IOutputWriter
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>
    /// Writes transcript lines to the target file using UTF-8 without a BOM.
    /// </summary>
    public async Task WriteAsync(
        string outputPath,
        IReadOnlyList<FilteredSegment> segments,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var writer = new StreamWriter(outputPath, append: false, Utf8NoBom);

        foreach (var segment in segments)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await writer.WriteAsync(segment.Start.ToString().AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.WriteAsync("->".AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.WriteAsync(segment.End.ToString().AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.WriteAsync(": ".AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.WriteLineAsync(segment.Text.AsMemory(), cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Builds the output file content in the legacy timestamped text format.
    /// Used by tests to verify formatting without writing to disk.
    /// </summary>
    public string BuildOutputText(IReadOnlyList<FilteredSegment> segments)
    {
        var builder = new StringBuilder();

        foreach (var segment in segments)
        {
            builder.Append(segment.Start);
            builder.Append("->");
            builder.Append(segment.End);
            builder.Append(": ");
            builder.AppendLine(segment.Text);
        }

        return builder.ToString();
    }
}
