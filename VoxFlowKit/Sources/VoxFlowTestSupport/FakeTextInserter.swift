import Foundation
import Synchronization
import VoxFlowCore

public final class FakeTextInserter: TextInserting, Sendable {
    private let result: Mutex<InsertionResult>
    private let inserted = Mutex<[String]>([])

    public init(result: InsertionResult = .inserted(appName: "Mail")) { self.result = Mutex(result) }

    public func setResult(_ r: InsertionResult) { result.withLock { $0 = r } }
    public var insertedTexts: [String] { inserted.withLock { $0 } }

    public func insert(_ text: String) async -> InsertionResult {
        inserted.withLock { $0.append(text) }
        return result.withLock { $0 }
    }
}
