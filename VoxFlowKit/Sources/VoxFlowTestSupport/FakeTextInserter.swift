import Foundation
import Synchronization
import VoxFlowCore

public final class FakeTextInserter: TextInserting, Sendable {
    private let result: Mutex<InsertionResult>
    private let inserted = Mutex<[String]>([])
    private let offsets = Mutex<[Int?]>([])

    public init(result: InsertionResult = .inserted(appName: "Mail")) { self.result = Mutex(result) }

    public func setResult(_ r: InsertionResult) { result.withLock { $0 = r } }
    public var insertedTexts: [String] { inserted.withLock { $0 } }
    public var cursorOffsets: [Int?] { offsets.withLock { $0 } }

    public func insert(_ text: String, cursorOffset: Int?) async -> InsertionResult {
        inserted.withLock { $0.append(text) }
        offsets.withLock { $0.append(cursorOffset) }
        return result.withLock { $0 }
    }
}
