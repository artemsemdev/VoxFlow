import AppKit
import Darwin
import Foundation
import VoxFlowMCP

/// Client-launched native transport. No HTTP listener, bearer token, or persisted client grant.
@MainActor
final class MCPStdioHost {
    private let services: AppServices
    private let output: FileHandle
    private let writer = DispatchQueue(label: "dev.artemsem.voxflow.mcp.stdout")
    private var requests: [UUID: Task<Void, Never>] = [:]

    private init(services: AppServices, output: FileHandle) {
        self.services = services
        self.output = output
    }

    static func main() {
        // Native speech backends may log to stdout. Preserve the protocol pipe separately,
        // redirect process stdout to stderr before constructing any production services.
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(EXIT_FAILURE) }
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let services = AppServices.live()
        services.dictation.start()
        let host = MCPStdioHost(services: services, output: output)
        Task {
            let success = await host.run()
            services.dictation.escape()
            await services.dictationController.escape()
            await services.engine.unload()
            exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        application.run()
    }

    private func run() async -> Bool {
        var framer = MCPStdioFramer()
        defer { for task in requests.values { task.cancel() } }
        do {
            for try await byte in FileHandle.standardInput.bytes {
                guard let data = try framer.append(byte) else { continue }
                // Keep both executing requests and queued/blocked response writes bounded.
                guard requests.count < 8 else { throw MCPStdioFramer.Failure.tooLarge }
                let token = UUID()
                requests[token] = Task {
                    defer { self.requests[token] = nil }
                    let response: Data?
                    do {
                        let request = try MCPStdioFramer.request(data)
                        response = await self.services.mcpServerService.handleStdio(request)
                    } catch {
                        response = try? JSONEncoder().encode(MCPStdioFramer.errorResponse(for: error))
                    }
                    guard !Task.isCancelled, let response else { return }
                    do { try await self.write(response) }
                    catch {
                        // A client that closes its response pipe must not leave capture running.
                        self.services.dictation.escape()
                        for task in self.requests.values { task.cancel() }
                        exit(EXIT_FAILURE)
                    }
                }
            }
            // Closing stdin terminates the subprocess and cancels its in-flight requests.
            return true
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("VoxFlow stdio input rejected: \(error)\n".utf8))
            return false
        }
    }

    private func write(_ data: Data) async throws {
        guard data.count <= 8_388_608 else { throw MCPStdioFramer.Failure.tooLarge }
        var line = data
        line.append(10)
        let lineToWrite = line
        let output = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.async {
                do {
                    try output.write(contentsOf: lineToWrite)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
