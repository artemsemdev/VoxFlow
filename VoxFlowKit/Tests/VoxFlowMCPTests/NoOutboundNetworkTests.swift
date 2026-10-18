import Foundation
import Testing

/// Plan ruling 10: "The server never opens a connection; the privacy footer keeps saying '0 bytes
/// sent since install'. A test asserts `VoxFlowMCP` contains no `URLSession`/`NWConnection(to:)`
/// use." ADR-008 claims this test exists; final review F4 found that it did not. It does now.
///
/// This scans the module's own sources rather than observing behaviour at runtime: the property is
/// "this module cannot reach the network at all", which no single execution path can demonstrate.
/// It is deliberately blunt — a new outbound call is either spelled one of these ways or it is a
/// deliberate act that should also update ADR-008.
@Suite("VoxFlowMCP makes no outbound network calls")
struct NoOutboundNetworkTests {
    /// The module's source directory, located from this file rather than a resource bundle (the
    /// test target has none): …/VoxFlowKit/Tests/VoxFlowMCPTests/ → …/VoxFlowKit/Sources/VoxFlowMCP/
    private static var moduleSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // VoxFlowKit/
            .appendingPathComponent("Sources/VoxFlowMCP")
    }

    @Test("no source file references URLSession, NWConnection, Network or any socket API")
    func sourcesMakeNoOutboundCalls() throws {
        let forbidden = ["URLSession", "NWConnection", "import Network", "URLRequest",
                         "CFSocket", "Darwin.connect(", "NWBrowser", "NWListener"]
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.moduleSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "found no VoxFlowMCP sources at \(Self.moduleSources.path)")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!source.contains(token),
                        "\(file.lastPathComponent) references \(token) — VoxFlowMCP must stay transport-free (plan ruling 10, ADR-008)")
            }
        }
    }
}
