import Foundation
import Synchronization
@testable import VoxFlow

/// Scripted `ContactsImporting` for `DictionaryViewModel` tests: authorization/request/fetch are all
/// controllable, and `fireChange()` simulates a `CNContactStoreDidChange` notification arriving —
/// same scripted-fake shape as `FakePermissions`.
final class FakeContacts: ContactsImporting, Sendable {
    private struct State {
        var authorization: PermissionState
        var requestResult: PermissionState
        var names: [String]
        var fetchError: Error?
        var requests = 0
        var fetches = 0
        var handlers: [@Sendable () -> Void] = []
    }
    private let state: Mutex<State>

    init(authorization: PermissionState = .notDetermined, requestResult: PermissionState = .granted, names: [String] = []) {
        state = Mutex(State(authorization: authorization, requestResult: requestResult, names: names, fetchError: nil))
    }

    var requests: Int { state.withLock { $0.requests } }
    var fetches: Int { state.withLock { $0.fetches } }

    func setNames(_ names: [String]) { state.withLock { $0.names = names } }
    func setFetchError(_ error: Error?) { state.withLock { $0.fetchError = error } }
    func setAuthorization(_ value: PermissionState) { state.withLock { $0.authorization = value } }

    /// Fires every registered `observeChanges` handler, off the main actor — mirrors how
    /// `CNContactStoreDidChange` really arrives, on an arbitrary thread.
    func fireChange() {
        let handlers = state.withLock { $0.handlers }
        for handler in handlers { handler() }
    }

    func authorization() -> PermissionState { state.withLock { $0.authorization } }

    func request() async -> PermissionState {
        state.withLock { $0.requests += 1; $0.authorization = $0.requestResult; return $0.requestResult }
    }

    func fetchNames() async throws -> [String] {
        state.withLock { $0.fetches += 1 }
        if let error = state.withLock({ $0.fetchError }) { throw error }
        return state.withLock { $0.names }
    }

    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ContactsChangeToken {
        state.withLock { $0.handlers.append(handler) }
        return ContactsChangeToken {}
    }
}

struct FakeContactsFetchError: Error {}

/// A `ContactsImporting` whose `fetchNames()` never returns until `unblock()` is called — lets a test
/// (or a render case) observe `.importing(count: nil)` mid-fetch and `.importing(count:)` /
/// `.done(count:)` right after, deterministically, instead of racing a fast in-memory fetch. Shared
/// between `DictionaryViewModelTests` (F2/F7) and `DictionaryRenderTests` (which used to keep a
/// private copy of this same shape).
final class BlockingFakeContacts: ContactsImporting, Sendable {
    private let continuation = Mutex<CheckedContinuation<[String], Error>?>(nil)
    private let names: [String]
    init(names: [String]) { self.names = names }
    func authorization() -> PermissionState { .granted }
    func request() async -> PermissionState { .granted }
    func fetchNames() async throws -> [String] {
        try await withCheckedThrowingContinuation { k in self.continuation.withLock { $0 = k } }
    }
    func unblock() { continuation.withLock { $0?.resume(returning: names); $0 = nil } }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ContactsChangeToken { ContactsChangeToken {} }
}
