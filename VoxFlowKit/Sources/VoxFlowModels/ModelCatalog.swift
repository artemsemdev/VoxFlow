import Foundation
import VoxFlowCore

/// The models VoxFlow can download (design ST-03). Checksums verified 2026-09-07.
public enum ModelCatalog {
    private static let whisperBase = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    public static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo", role: .speech,
            downloadURL: whisperBase.appendingPathComponent("ggml-large-v3-turbo.bin"),
            sizeInBytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            languagesSummary: "99 languages · best accuracy on M-series", isDefault: true),
        ModelDescriptor(
            id: "whisper-small", displayName: "Whisper small", role: .speech,
            downloadURL: whisperBase.appendingPathComponent("ggml-small.bin"),
            sizeInBytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            languagesSummary: "99 languages · for 8 GB Macs", isDefault: false),
        ModelDescriptor(
            id: "qwen2.5-3b-instruct-q4", displayName: "Qwen2.5 3B Instruct (4-bit)", role: .style,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
            sizeInBytes: 2_100_000_000,   // TODO(phase 5): pin the exact size and checksum when the style engine lands
            sha256: "",
            languagesSummary: "powers Formal / Casual / Very casual rewriting", isDefault: true),
    ]

    public static func model(id: String) -> ModelDescriptor? { all.first { $0.id == id } }
}
