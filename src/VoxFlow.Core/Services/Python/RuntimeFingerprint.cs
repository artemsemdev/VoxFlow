using System;
using System.IO;
using System.Security.Cryptography;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Computes stable content fingerprints for the files that define a managed
/// speaker-labeling runtime — the pinned requirements file and the bundled
/// diarization sidecar script — so the stamp can detect when either has changed.
/// </summary>
public static class RuntimeFingerprint
{
    /// <summary>
    /// SHA-256 of the file's bytes, formatted as <c>sha256:&lt;lowercase-hex&gt;</c>.
    /// </summary>
    /// <exception cref="FileNotFoundException">The file does not exist.</exception>
    public static string HashFile(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Cannot fingerprint a file that does not exist.", path);
        }

        using var stream = File.OpenRead(path);
        var hash = SHA256.HashData(stream);
        return "sha256:" + Convert.ToHexStringLower(hash);
    }
}
