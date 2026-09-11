import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Temporary history resource lifetime", .timeLimit(.minutes(1)))
@MainActor
struct TemporaryHistoryLifetimeTests {
    private enum FixtureError: Error {
        case storeUnavailable
    }

    private final class WeakReference<Value: AnyObject> {
        weak var value: Value?
    }

    private struct Key: HistoryKeyProviding {
        let key = SymmetricKey(size: .bits256)
        func historyKey() throws -> HistoryKey { .init(key: key, isNewlyCreated: false) }
    }

    @Test("a store escaping its service retains the directory until its last connection closes")
    func escapedStore() async throws {
        let clock = FakeClock()
        let closedBeforeRemoval = Mutex<Bool?>(nil)
        let weakDirectory = WeakReference<TemporaryDirectory>()
        let weakService = WeakReference<HistoryService>()
        let weakStore = WeakReference<DictationStore>()
        let weakDatabase = WeakReference<VoxFlowDatabase>()
        let weakQueue = WeakReference<AnyObject>()
        func makeEscapedStore() async throws -> (DictationStore, URL) {
            let directory = TemporaryDirectory { url in
                let file = url.appendingPathComponent("voxflow.sqlite")
                let closed = FileManager.default.fileExists(atPath: file.path) && Self.openDescriptor(for: file) == nil
                closedBeforeRemoval.withLock { $0 = closed }
            }
            let settings = DictationSettings(store: InMemoryKeyValueStore())
            settings.retentionDays = 0
            var service: HistoryService? = HistoryService(directory: directory, settings: settings, keyProvider: { Key() }, clock: clock)
            await service?.ready()
            await clock.waitForSleepers(1)
            guard let store = service?.store else {
                Issue.record("history store did not open")
                throw FixtureError.storeUnavailable
            }
            weakDirectory.value = directory
            weakService.value = service
            weakStore.value = store
            weakDatabase.value = service?.database
            weakQueue.value = service?.database?.queue
            service = nil
            return (store, directory.url)
        }
        func useStoreAndRelease() async throws -> URL {
            let (store, url) = try await makeEscapedStore()
            let serviceReleased = weakService.value == nil
            #expect(serviceReleased)
            let file = url.appendingPathComponent("voxflow.sqlite")
            let fileExists = FileManager.default.fileExists(atPath: file.path)
            let descriptorIsOpen = Self.openDescriptor(for: file) != nil
            let count = try store.count()
            #expect(fileExists)
            #expect(descriptorIsOpen)
            #expect(count == 0)
            return url
        }
        let url = try await useStoreAndRelease()
        let serviceReleased = weakService.value == nil
        let storeReleased = weakStore.value == nil
        let databaseReleased = weakDatabase.value == nil
        let queueReleased = weakQueue.value == nil
        let directoryReleased = weakDirectory.value == nil
        let descriptorIsClosed = Self.openDescriptor(for: url.appendingPathComponent("voxflow.sqlite")) == nil
        #expect(serviceReleased)
        #expect(storeReleased)
        #expect(databaseReleased)
        #expect(queueReleased)
        #expect(directoryReleased)
        #expect(descriptorIsClosed)
        #expect(closedBeforeRemoval.withLock { $0 } == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Inspect only this test process's existing descriptors; never open another connection.
    private nonisolated static func openDescriptor(for url: URL) -> Int32? {
        var file = stat()
        guard stat(url.path, &file) == 0 else { return nil }
        for descriptor in 0..<getdtablesize() {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_dev == file.st_dev, info.st_ino == file.st_ino {
                return descriptor
            }
        }
        return nil
    }
}
