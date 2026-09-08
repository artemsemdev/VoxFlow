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

- `HistoryKeyProviding` is a protocol with one method, `historyKey() throws -> HistoryKey`
  (`HistoryKey` pairs the `SymmetricKey` with `isNewlyCreated: Bool`, so a caller can
  tell "derived/read an existing key" from "just generated one" — see below).
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
  - `KeychainKeyProvider` keys its Keychain item off `service`/`account` (default
    `dev.artemsem.voxflow` / `history-key`); `SecureEnclaveKeyProvider` uses the
    same `service` but `account + ".se"`, so the two providers never collide on
    the same Keychain item even for the same nominal account — which matters
    because it means an SE→Keychain provider switch (`SecureEnclave.isAvailable`
    flipping) looks exactly like "no item yet" to whichever provider is asked,
    not like a natural handoff. Both are scoped `ThisDeviceOnly`.
  - Neither provider silently mints a replacement key over an already-encrypted
    database: `historyKey()` returns whether *this call* is the one that
    generated and stored the key (`HistoryKey.isNewlyCreated`), and
    `DictationStore.init` throws `StorageError.keyLost` when that's true but the
    database already has `encrypted = 1` rows — a Keychain reset, a re-signing
    identity change (see below), or the SE/Keychain provider switch above all
    surface this way, as an explicit error the caller must handle, never as a
    fresh key quietly shadowing rows that are now permanently unreadable.
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
  toggle off (no key provider) — or if the encryption key itself is lost (see
  `StorageError.keyLost` above). `DictationStore.fetch`/`search` never fail because
  of it: `record(from:)` decodes per row, and an undecryptable row comes back as a
  `DictationRecord` with `isUnreadable = true` and empty `text`/`rawText` (all other
  columns still filled) rather than throwing for the whole call. The phase-3b History
  view model renders such a row as "Encrypted — turn on 'Encrypt history at rest' to
  read"; `search` skips these rows outright, since there's no text to match.
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
  Secure Enclave hardware and a signing identity it accepts, so it is not exercised by
  CI either. It has the same shape of gated test as the Keychain provider
  (`VOXFLOW_SE_TESTS=1`, `HistoryKeyProvidersTests.secureEnclave`), asserting the
  determinism the whole design leans on — re-deriving on a second, independent
  instance gives the same key — but it is a manual pre-release check on real
  hardware, not part of the default suite: run it once before cutting the 2.1.0
  release.
