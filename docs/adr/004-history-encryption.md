# ADR-004: History encryption: per-row AES-GCM with a Secure Enclave-wrapped key

Status: Accepted · Date: 2026-09-08

## Context

The design (ST-05) says "Key stored in the Secure Enclave" for the dictation history
database. The Secure Enclave cannot itself run AES-GCM over arbitrary text — it only
signs and does key agreement — so "stored in the Secure Enclave" has to mean the
symmetric AES key is derived from something the Secure Enclave holds, not encrypted
by it directly. Two more constraints narrow the design: CI VMs have no Secure Enclave
at all, and local builds are ad-hoc signed (ADR-001), so a real per-Mac Secure Enclave
key is only sometimes available, and the app still has to run everywhere.

## Decision

- `HistoryKeyProviding` is a protocol with one method, `historyKey() -> SymmetricKey`.
  `HistoryKeyProviders.default` picks an implementation by hardware/signature
  availability (`SecureEnclave.isAvailable`):
  - **`SecureEnclaveKeyProvider`** (when available): an ECIES-style wrap. A P-256
    key-agreement private key is generated inside the Secure Enclave (it never
    leaves; only its opaque `dataRepresentation` handle is persisted) alongside a
    stored public "salt" key whose private half is discarded on purpose. Each call
    to `historyKey()` re-runs `sharedSecretFromKeyAgreement` between the SE private
    key and the stored salt public key, then derives the 256-bit AES key with
    HKDF-SHA256 (`salt: "VoxFlow history"`). The AES key itself is never stored —
    only the two Keychain-held handles needed to re-derive it.
  - **`KeychainKeyProvider`** (fallback: no Secure Enclave, e.g. CI VMs): a random
    256-bit key generated once and stored directly as a Keychain generic password
    (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
  - Both providers key their Keychain items off `service`/`account` (default
    `dev.artemsem.voxflow` / `history-key`), scoped `ThisDeviceOnly`.
- `DictationCipher` wraps `AES.GCM` and seals/opens one `String` at a time; the
  combined box (nonce + ciphertext + tag) is the BLOB stored in SQLite.
- `DictationStore` accepts an optional key provider. When present, every row's
  `text`/`raw_text` is sealed on insert and an `encrypted BOOLEAN` column records
  that fact per row; when absent (the user has the "Encrypt history at rest" toggle
  off), rows are stored as plain UTF-8 and `encrypted = false`. The flag is
  per-row, not per-database, so toggling encryption never rewrites history.
- Search (`DictationStore.search`) decrypts every candidate row in memory and does a
  case-insensitive substring match — history is thousands of rows, not millions, so
  no encrypted-index scheme is needed.
- Retention (`RetentionPolicy`, choices `[7, 30, 90, 365, 0]` days, default 30) purges
  by `created_at` regardless of the `encrypted` flag; `RetentionRunner` runs a pass at
  `start()` and every 24 h.

## Consequences

- A row written with `encrypted = true` is unreadable if the user later turns the
  toggle off (no key provider): `DictationStore` throws `StorageError.corruptRow` for
  it. The phase-3b History view model is expected to catch this per row and render it
  as "Encrypted — turn on 'Encrypt history at rest' to read" rather than failing the
  whole list.
- The Secure Enclave-derived key is a per-Mac, per-Keychain secret: moving
  `voxflow.sqlite` to another Mac (or restoring the Keychain to a different machine)
  loses access to every encrypted row. This is by design — the design brief never
  asked for cross-device history — and should be called out wherever history export
  or backup is documented.
- Because both providers store their material in the Keychain under the app's
  service/account, phase 7's move to Developer ID signing must keep the same bundle
  identifier; otherwise the Keychain items (and therefore every encrypted row) become
  unreachable after re-signing.
- CI and any ad-hoc-signed local build exercise the `KeychainKeyProvider` path only
  (its own Keychain round-trip is gated behind `VOXFLOW_KEYCHAIN_TESTS=1`, not run by
  default). Provider *selection* (`HistoryKeyProviders.select`) is a pure function and
  is unit tested directly; `SecureEnclaveKeyProvider.historyKey()` itself needs real
  Secure Enclave hardware and is not exercised by CI.
