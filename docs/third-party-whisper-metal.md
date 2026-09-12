# Whisper Metal artifact provenance

The speech binary stays pinned to upstream whisper.cpp `v1.9.2`, commit
`306c88f4d1286aec1bf96e544632897886af5501`. Before packaging a replacement
XCFramework, apply [198-metal-warnings.patch](../third_party/whisper.cpp/198-metal-warnings.patch)
from the repository root.

The patch excludes `ksigns64`, `kvalues_iq4nl`, and `kvalues_fp4` only from the
Metal translation unit; CPU and other backend definitions are unchanged. It also
removes the unused `bilinear_tri` helper. GPU and flash-attention settings remain
enabled in `WhisperCppEngine`.

Build the macOS 15 universal static XCFramework and its deterministic archive with:

```bash
scripts/build_whisper_xcframework.sh /tmp/voxflow-whisper-artifact
```

The script clones and verifies the pinned commit, applies the reviewed patch,
builds arm64 and x86_64 with the embedded Metal source and Accelerate backend,
compiles that exact generated Metal source with warnings as errors, and records
both SwiftPM and SHA-256 checksums. A local source repository can be passed as the
second argument for an offline rebuild; the script still makes a clean clone and
checks out the pinned commit. The reviewed Xcode 26.6 / Metal 32023.883 build is:

```text
whisper-v1.9.2-metal-macos.xcframework.zip
SHA-256 fbe2d8e5167c79d6ca31b9de1ad3884ef0c44910f120148ca92de0863cea0427
```

`VoxFlowKit/Package.swift` pins the archive under the VoxFlow release tag
`whisper-v1.9.2-voxflow.1` with this checksum. Future replacements must be independently
reviewed and published under a new version before updating the package URL.

Validation must compile the generated embedded source with the Metal compiler and
run the unchanged installed-model integration on a cold per-run Metal cache. The
baseline source reports four warnings; the patched source produces no diagnostics
with Xcode 26.6 Metal 32023.883.
