import Foundation
import Synchronization
import Testing
@testable import VoxFlow

@Suite("Selected file access lifetime")
struct FileInputAccessTests {
    @Test func balancesSuccessfulScopesAndDoesNotDoubleAcquire() {
        let acquired = Counter(), released = Counter()
        let granted = URL(fileURLWithPath: "/tmp/granted.aiff")
        let ordinary = URL(fileURLWithPath: "/tmp/ordinary.aiff")
        var access: FileInputAccess? = FileInputAccess(start: { url in
            acquired.withLock { $0 += 1 }; return url == granted
        }, stop: { url in
            #expect(url == granted); released.withLock { $0 += 1 }
        })
        access?.retain([granted, ordinary, granted])
        access?.retain([granted])
        #expect(acquired.withLock { $0 } == 2)
        #expect(released.withLock { $0 } == 0)
        access = nil
        #expect(released.withLock { $0 } == 1)
    }
}
