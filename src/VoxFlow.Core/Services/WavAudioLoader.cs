using System;
using System.Buffers.Binary;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;

namespace VoxFlow.Core.Services;

/// <summary>
/// Reads WAV data into normalized floating-point samples for Whisper processing.
/// </summary>
internal sealed class WavAudioLoader : IWavAudioLoader
{
    private const ushort PcmFormat = 1;
    private const ushort IeeeFloatFormat = 3;
    private const int RiffHeaderSize = 12;
    private const int FmtChunkMinSize = 16;

    /// <summary>
    /// Loads audio samples from a WAV file and validates the expected output format.
    /// </summary>
    public async Task<float[]> LoadSamplesAsync(
        string wavPath,
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        var fileBytes = await File.ReadAllBytesAsync(wavPath, cancellationToken).ConfigureAwait(false);
        var span = fileBytes.AsSpan();

        if (span.Length < RiffHeaderSize)
        {
            throw new InvalidOperationException("The generated WAV file is too small to contain a valid RIFF/WAVE header.");
        }

        if (!IsChunkId(span[..4], "RIFF"u8) || !IsChunkId(span[8..12], "WAVE"u8))
        {
            throw new InvalidOperationException("The generated WAV file has an invalid RIFF/WAVE header.");
        }

        ushort audioFormat = 0;
        ushort channelCount = 0;
        uint sampleRate = 0;
        ushort bitsPerSample = 0;
        ReadOnlySpan<byte> data = default;

        // Walk the RIFF chunks manually so the loader accepts valid files
        // even when optional chunks appear before the audio payload.
        var position = RiffHeaderSize;

        while (position + 8 <= span.Length)
        {
            var chunkId = span.Slice(position, 4);
            var chunkSize = BinaryPrimitives.ReadUInt32LittleEndian(span.Slice(position + 4, 4));
            var chunkDataStart = position + 8;

            if (chunkDataStart + chunkSize > (uint)span.Length)
            {
                break;
            }

            if (IsChunkId(chunkId, "fmt "u8) && chunkSize >= FmtChunkMinSize)
            {
                var fmt = span.Slice(chunkDataStart, (int)chunkSize);
                audioFormat = BinaryPrimitives.ReadUInt16LittleEndian(fmt[..2]);
                channelCount = BinaryPrimitives.ReadUInt16LittleEndian(fmt[2..4]);
                sampleRate = BinaryPrimitives.ReadUInt32LittleEndian(fmt[4..8]);
                // Skip byteRate (4 bytes) and blockAlign (2 bytes).
                bitsPerSample = BinaryPrimitives.ReadUInt16LittleEndian(fmt[14..16]);
            }
            else if (IsChunkId(chunkId, "data"u8))
            {
                // Keep the last seen data chunk, which is the payload the app transcribes.
                data = span.Slice(chunkDataStart, (int)chunkSize);
            }

            // Advance to the next chunk, honoring the WAV padding byte rule.
            position = chunkDataStart + (int)chunkSize;
            if ((chunkSize & 1) == 1 && position < span.Length)
            {
                position++;
            }
        }

        if (data.IsEmpty)
        {
            throw new InvalidOperationException("The generated WAV file does not contain an audio data chunk.");
        }

        if (channelCount != options.OutputChannelCount || sampleRate != options.OutputSampleRate)
        {
            throw new InvalidOperationException(
                $"Unexpected WAV format. Expected {options.OutputChannelCount} channel(s) at {options.OutputSampleRate} Hz, got {channelCount} channel(s) at {sampleRate} Hz.");
        }

        return ConvertToFloatSamples(audioFormat, bitsPerSample, data);
    }

    /// <summary>
    /// Converts supported WAV sample encodings into floating-point samples.
    /// </summary>
    private static float[] ConvertToFloatSamples(ushort audioFormat, ushort bitsPerSample, ReadOnlySpan<byte> data)
    {
        return audioFormat switch
        {
            PcmFormat => ConvertPcmToFloat(bitsPerSample, data),
            IeeeFloatFormat when bitsPerSample == 32 => ConvertFloat32(data),
            _ => throw new InvalidOperationException(
                $"Unsupported WAV sample format: format={audioFormat}, bitsPerSample={bitsPerSample}.")
        };
    }

    /// <summary>
    /// Converts PCM samples to floating-point values based on bit depth.
    /// </summary>
    private static float[] ConvertPcmToFloat(ushort bitsPerSample, ReadOnlySpan<byte> data)
    {
        return bitsPerSample switch
        {
            8 => ConvertPcm8(data),
            16 => ConvertPcm16(data),
            24 => ConvertPcm24(data),
            32 => ConvertPcm32(data),
            _ => throw new InvalidOperationException($"Unsupported PCM bit depth: {bitsPerSample}.")
        };
    }

    /// <summary>
    /// Converts unsigned 8-bit PCM samples to normalized floats.
    /// </summary>
    private static float[] ConvertPcm8(ReadOnlySpan<byte> data)
    {
        var samples = new float[data.Length];

        for (var index = 0; index < data.Length; index++)
        {
            samples[index] = (data[index] - 128) / 128f;
        }

        return samples;
    }

    /// <summary>
    /// Converts signed 16-bit PCM samples to normalized floats.
    /// </summary>
    private static float[] ConvertPcm16(ReadOnlySpan<byte> data)
    {
        var sampleCount = data.Length / 2;
        var samples = new float[sampleCount];

        for (var index = 0; index < sampleCount; index++)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(data.Slice(index * 2, 2));
            samples[index] = sample / 32768f;
        }

        return samples;
    }

    /// <summary>
    /// Converts signed 24-bit PCM samples to normalized floats.
    /// </summary>
    private static float[] ConvertPcm24(ReadOnlySpan<byte> data)
    {
        var sampleCount = data.Length / 3;
        var samples = new float[sampleCount];

        for (var index = 0; index < sampleCount; index++)
        {
            var baseOffset = index * 3;
            // 24-bit PCM is stored as three bytes, so sign extension has to be done manually.
            var sample = data[baseOffset] |
                         (data[baseOffset + 1] << 8) |
                         (data[baseOffset + 2] << 16);

            if ((sample & 0x00800000) != 0)
            {
                sample |= unchecked((int)0xFF000000);
            }

            samples[index] = sample / 8388608f;
        }

        return samples;
    }

    /// <summary>
    /// Converts signed 32-bit PCM samples to normalized floats.
    /// </summary>
    private static float[] ConvertPcm32(ReadOnlySpan<byte> data)
    {
        var sampleCount = data.Length / 4;
        var samples = new float[sampleCount];

        for (var index = 0; index < sampleCount; index++)
        {
            var sample = BinaryPrimitives.ReadInt32LittleEndian(data.Slice(index * 4, 4));
            samples[index] = sample / 2147483648f;
        }

        return samples;
    }

    /// <summary>
    /// Converts 32-bit float samples without additional scaling.
    /// </summary>
    private static float[] ConvertFloat32(ReadOnlySpan<byte> data)
    {
        var sampleCount = data.Length / 4;
        var samples = new float[sampleCount];

        for (var index = 0; index < sampleCount; index++)
        {
            samples[index] = BinaryPrimitives.ReadSingleLittleEndian(data.Slice(index * 4, 4));
        }

        return samples;
    }

    /// <summary>
    /// Compares a chunk identifier against the expected WAV marker using a byte-level comparison.
    /// </summary>
    private static bool IsChunkId(ReadOnlySpan<byte> actual, ReadOnlySpan<byte> expected)
    {
        return actual.SequenceEqual(expected);
    }
}
