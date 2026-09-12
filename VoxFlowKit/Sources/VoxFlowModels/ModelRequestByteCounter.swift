import Foundation
import Observation
import Synchronization
import VoxFlowCore

/// URLSession-measured HTTP request bytes for model downloads, starting with the first launch
/// that supports accounting. Response data, local MCP traffic and TLS overhead are not counted.
@Observable
public final class ModelRequestByteCounter: Sendable {
    private enum Keys {
        static let bytes = "network.modelRequestBytesSent"
        static let started = "network.requestTrackingStartedAt"
    }
    private let store: any KeyValueStore
    private let total: Mutex<Int64>
    public let trackingStartedAt: Date
    public var bytesSent: Int64 {
        access(keyPath: \.bytesSent)
        return total.withLock { $0 }
    }
    public var summary: String {
        let count = bytesSent
        return "\(count) \(count == 1 ? "byte" : "bytes") sent since tracking began"
    }

    public var measurementDetails: String {
        "HTTP request headers and bodies for model downloads, measured since "
            + trackingStartedAt.formatted(date: .abbreviated, time: .shortened)
            + ". Updated when requests finish, including redirects, retries and failed attempts. "
            + "Received model data, local MCP replies, TLS overhead and earlier traffic are not counted."
    }

    public init(store: any KeyValueStore, now: Date = Date()) {
        self.store = store
        total = Mutex(max(0, store.string(forKey: Keys.bytes).flatMap(Int64.init) ?? 0))
        trackingStartedAt = store.string(forKey: Keys.started).flatMap(Double.init)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? now
        store.set(String(trackingStartedAt.timeIntervalSince1970), forKey: Keys.started)
    }

    public func record(headerBytes: Int64, bodyBytes: Int64) {
        let addition = Self.add(max(0, headerBytes), max(0, bodyBytes))
        guard addition > 0 else { return }
        // The observation callbacks run outside our lock; observers may read bytesSent again.
        // Serialize both accumulation and persistence so concurrent task metrics cannot overwrite
        // a newer persisted total with an older one.
        withMutation(keyPath: \.bytesSent) {
            total.withLock {
                $0 = Self.add($0, addition)
                store.set(String($0), forKey: Keys.bytes)
            }
        }
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
