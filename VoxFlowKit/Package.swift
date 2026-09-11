// swift-tools-version: 6.0
import PackageDescription

// Module dependency graph (spec section 3). Core depends on nothing but Foundation;
// every other module depends on Core; Files may use Audio/Speech/Models later.
let package = Package(
    name: "VoxFlowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoxFlowCore", targets: ["VoxFlowCore"]),
        .library(name: "VoxFlowAudio", targets: ["VoxFlowAudio"]),
        .library(name: "VoxFlowSpeech", targets: ["VoxFlowSpeech"]),
        .library(name: "VoxFlowModels", targets: ["VoxFlowModels"]),
        .library(name: "VoxFlowFiles", targets: ["VoxFlowFiles"]),
        .library(name: "VoxFlowDictation", targets: ["VoxFlowDictation"]),
        .library(name: "VoxFlowStorage", targets: ["VoxFlowStorage"]),
        .library(name: "VoxFlowStyling", targets: ["VoxFlowStyling"]),
        .library(name: "VoxFlowMCP", targets: ["VoxFlowMCP"]),
        .library(name: "VoxFlowLLM", targets: ["VoxFlowLLM"]),
        .library(name: "VoxFlowTestSupport", targets: ["VoxFlowTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "VoxFlowCore"),
        .target(name: "VoxFlowAudio", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowTestSupport", dependencies: ["VoxFlowCore", "VoxFlowDictation"]),
        .target(name: "VoxFlowSpeech", dependencies: ["VoxFlowCore", "whisper"]),
        .target(name: "VoxFlowModels", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowFiles", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowDictation", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowStorage", dependencies: ["VoxFlowCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "VoxFlowStyling", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowMCP", dependencies: ["VoxFlowCore"]),
        .target(name: "VoxFlowLLM", dependencies: ["VoxFlowCore", "llama"]),

        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10881/llama-b10881-xcframework.zip",
            checksum: "7a86995c5f2127f897c0eeec78e0f32fec8fac750027ea1707885fbc5dbcebcd"
        ),

        .testTarget(name: "VoxFlowCoreTests", dependencies: ["VoxFlowCore", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowAudioTests", dependencies: ["VoxFlowAudio", "VoxFlowTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VoxFlowSpeechTests", dependencies: ["VoxFlowSpeech", "VoxFlowAudio", "VoxFlowTestSupport", "VoxFlowDictation"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "VoxFlowModelsTests", dependencies: ["VoxFlowModels", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowFilesTests", dependencies: ["VoxFlowFiles", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowDictationTests", dependencies: ["VoxFlowDictation", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowStorageTests", dependencies: ["VoxFlowStorage", "VoxFlowCore", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowStylingTests", dependencies: ["VoxFlowStyling", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowMCPTests", dependencies: ["VoxFlowMCP", "VoxFlowTestSupport"]),
        .testTarget(name: "VoxFlowLLMTests", dependencies: ["VoxFlowLLM", "VoxFlowTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)

// Xcode-generated package targets do not inherit the app's warning policy. Apply it to our own
// source and test targets; dependency packages retain their upstream build settings. This package
// is consumed as a local path dependency by the app, which permits these compiler flags.
for target in package.targets where target.type == .regular || target.type == .test {
    target.swiftSettings = (target.swiftSettings ?? []) + [.unsafeFlags(["-warnings-as-errors"])]
}
