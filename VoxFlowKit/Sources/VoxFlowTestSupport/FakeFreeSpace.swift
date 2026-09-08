import Foundation
import VoxFlowCore

public struct FakeFreeSpace: FreeSpaceProviding {
    public var available: Int64
    public init(available: Int64) { self.available = available }
    public func availableBytes(at directory: URL) throws -> Int64 { available }
}
