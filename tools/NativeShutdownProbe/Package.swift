// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeShutdownProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../VoxFlowKit")],
    targets: [.executableTarget(name: "NativeShutdownProbe", dependencies: [
        .product(name: "VoxFlowCore", package: "VoxFlowKit"),
        .product(name: "VoxFlowAudio", package: "VoxFlowKit"),
        .product(name: "VoxFlowSpeech", package: "VoxFlowKit"),
        .product(name: "VoxFlowLLM", package: "VoxFlowKit")
    ])]
)
