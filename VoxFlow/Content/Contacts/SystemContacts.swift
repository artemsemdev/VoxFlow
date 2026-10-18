import Contacts
import Foundation
import Synchronization

/// Production `ContactsImporting`: `CNContactStore` for authorization/fetch,
/// `CNContactStoreDidChange` for change notifications. Stateless (a fresh `CNContactStore` per call)
/// so the type itself stays trivially `Sendable` — no stored, non-`Sendable` Contacts object crosses
/// actor boundaries.
struct SystemContacts: ContactsImporting {
    func authorization() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func request() async -> PermissionState {
        await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }

    func fetchNames() async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var names: Set<String> = []
            try store.enumerateContacts(with: request) { contact, _ in
                let parts = [contact.givenName, contact.familyName].filter { !$0.isEmpty }
                guard !parts.isEmpty else { return }
                names.insert(parts.joined(separator: " "))
            }
            return names.sorted()
        }.value
    }

    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ContactsChangeToken {
        // `NotificationCenter.addObserver(forName:...)`'s returned token is an `NSObjectProtocol`
        // existential, which isn't `Sendable` — carrying it into `ContactsChangeToken`'s `@Sendable`
        // `cancel` closure (so it could call `removeObserver`) isn't expressible without
        // `@unchecked Sendable`. Instead, cancellation flips a `Sendable` `Mutex<Bool>` flag the
        // observer block checks before calling `handler` — the block itself stays registered for
        // the process's lifetime (in practice: as long as `DictionaryViewModel`, which is built once
        // and lives for the whole app run), it just becomes a permanent no-op once cancelled.
        let cancelled = Mutex(false)
        _ = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in
            guard !cancelled.withLock({ $0 }) else { return }
            handler()
        }
        return ContactsChangeToken {
            cancelled.withLock { $0 = true }
        }
    }
}
