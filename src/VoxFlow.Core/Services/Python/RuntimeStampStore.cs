using System;
using System.IO;
using System.Text.Json;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>Reads, writes, and deletes the speaker-labeling runtime stamp.</summary>
public interface IRuntimeStampStore
{
    /// <summary>
    /// Reads the stamp. A missing file is <see cref="RuntimeStampReadStatus.Missing"/>;
    /// an unreadable/invalid file is <see cref="RuntimeStampReadStatus.Corrupt"/>
    /// — neither throws, so callers map them to setup/repair states.
    /// </summary>
    RuntimeStampReadResult Read();

    /// <summary>Writes the stamp atomically, creating the directory if needed.</summary>
    void Write(SpeakerLabelingRuntimeStamp stamp);

    /// <summary>Deletes the stamp file if present; a no-op when already absent.</summary>
    void Delete();
}

/// <inheritdoc />
public sealed class RuntimeStampStore : IRuntimeStampStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _filePath;

    public RuntimeStampStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public RuntimeStampReadResult Read()
    {
        if (!File.Exists(_filePath))
        {
            return new RuntimeStampReadResult(RuntimeStampReadStatus.Missing, null);
        }

        try
        {
            var json = File.ReadAllText(_filePath);
            if (string.IsNullOrWhiteSpace(json))
            {
                return new RuntimeStampReadResult(RuntimeStampReadStatus.Corrupt, null);
            }

            var stamp = JsonSerializer.Deserialize<SpeakerLabelingRuntimeStamp>(json, SerializerOptions);
            return stamp is null
                ? new RuntimeStampReadResult(RuntimeStampReadStatus.Corrupt, null)
                : new RuntimeStampReadResult(RuntimeStampReadStatus.Ok, stamp);
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            return new RuntimeStampReadResult(RuntimeStampReadStatus.Corrupt, null);
        }
    }

    public void Write(SpeakerLabelingRuntimeStamp stamp)
    {
        ArgumentNullException.ThrowIfNull(stamp);

        var directory = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        // Write to a temp file then move into place so a crash mid-write never
        // leaves a half-written stamp that would read back as corrupt.
        var tempPath = _filePath + ".tmp";
        File.WriteAllText(tempPath, JsonSerializer.Serialize(stamp, SerializerOptions));
        File.Move(tempPath, _filePath, overwrite: true);
    }

    public void Delete()
    {
        if (File.Exists(_filePath))
        {
            File.Delete(_filePath);
        }
    }
}
