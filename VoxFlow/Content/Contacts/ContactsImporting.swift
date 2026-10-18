import Foundation

/// A live subscription to Contacts change notifications (design MW-03c "updates when Contacts
/// change") — cancels itself when it deallocates, same lifetime contract as Combine's
/// `AnyCancellable`, without pulling in Combine for one token type.
final class ContactsChangeToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

/// Reads the system Contacts book for the Dictionary page's "Learn names from Contacts" toggle
/// (design MW-03, MW-03c). A protocol so `DictionaryViewModel` tests can script every state
/// (`FakeContacts`) instead of touching the real `CNContactStore` / Contacts permission prompt.
protocol ContactsImporting: Sendable {
    /// The current Contacts authorization, without prompting.
    func authorization() -> PermissionState
    /// Prompts the user (only meaningful from `.notDetermined`) and returns the resulting state.
    func request() async -> PermissionState
    /// Every contact's "First Last" (first + last name, non-empty parts joined with a space),
    /// de-duplicated. Requires `.granted` authorization — throws otherwise.
    func fetchNames() async throws -> [String]
    /// Registers `handler` to fire whenever the Contacts database changes; the returned token keeps
    /// the subscription alive until it (or the owner) deallocates.
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ContactsChangeToken
}
