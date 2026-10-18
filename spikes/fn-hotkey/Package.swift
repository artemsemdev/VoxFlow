// swift-tools-version: 6.0
import PackageDescription

// Throwaway probe (phase 3a spike). Not built in CI, not shipped. See README.md.
let package = Package(
    name: "fn-hotkey",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "fn-hotkey"),
    ]
)
