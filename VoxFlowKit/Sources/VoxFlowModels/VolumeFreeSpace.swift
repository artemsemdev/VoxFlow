import Foundation
import VoxFlowCore

public struct VolumeFreeSpace: FreeSpaceProviding {
    public init() {}
    public func availableBytes(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
