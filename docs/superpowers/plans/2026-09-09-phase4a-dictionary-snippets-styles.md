# VoxFlow v2 Phase 4a — Dictionary, Snippets, Styles, rule-based styling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The three content pages of the main window backed by storage — Dictionary (MW-03, 03a, 03v, 03c, 03e), Snippets (MW-04, 04a, 04v, 04e), Styles (MW-05, 05a) — plus the deterministic text pipeline that makes them matter: `RuleStyler` (fillers, punctuation/capitalization, Formal/Casual/Very casual/Verbatim), `SnippetExpander`, per-app style overrides, and dictionary words fed to the speech engine as vocabulary. Phase 4b adds Home, Settings › General, the MCP tab (UI), the menu bar and notifications.

**Architecture:** `VoxFlowStorage` gains a shared `VoxFlowDatabase` (one `DatabaseQueue`, migrations v1 + v2) with `DictionaryStore`, `SnippetStore`, `StyleOverrideStore`; `DictationStore` keeps its API on the same queue. `VoxFlowCore` gains `TextStyle`, `StylingOptions`, `TextStyler`. `VoxFlowStyling` implements `RuleStyler` (pure), `SnippetExpander` (pure), `StyleResolver` (pure). In the app, a `StyledTranscriber` decorator around `WindowedTranscriber` produces `DictationResult.text` from `rawText` using the resolved style for the app captured at fn-down; the dictionary feeds `TranscriptionOptions.vocabulary`. Pages follow the established pattern: `@Observable @MainActor` view models over `HistoryService`-style async wrappers; views thin; render tests compared with the canvas.

**Tech Stack:** Swift 6, GRDB 7.11.1, SwiftUI (macOS 15 grouped forms, sheets), Contacts framework (`CNContactStore`) behind a protocol, Swift Testing, XcodeGen.

**Spec:** design spec §1, §5 (tables `dictionary`, `snippets`, `app_style_overrides`); canvas 1c MW-03/MW-04/MW-05 (PDF page 11–12 for the window frame), 2c sheets (page 4: MW-03v, MW-04v; page 8–9: MW-03a "Add word", MW-04a "New snippet", MW-05a "Add app override"), 2d empty states (page 9: MW-03e, MW-04e), MW-03c Contacts states (page 4–5), 3d "Sheets & alerts"/"Toggles", 3e. Issue #111 (part 1).

**Rulings (binding):**
1. **Styling in 4a is rule-based only** (`RuleStyler`); the LLM (phase 5) will replace the *rewrite* step behind the same `TextStyler` protocol. Fillers and auto-punctuation are global toggles layered under the chosen style (canvas MW-05). `Verbatim` = passthrough (no fillers removed, no punctuation).
2. **Style resolution:** per-app override (by bundle id) wins over the default style; no override → default (Casual out of the box).
3. **Where styling runs:** in the app's `StyledTranscriber` decorator (`DictationTranscribing`), after the window loop returns; `rawText` stays the engine output; `text` is styled; History stores both plus the style name. Partial text events stay raw.
4. **Snippets** expand in the styled text: a token equal to a trigger (`/sig`) or its spoken form (`slash sig`, case-insensitive) is replaced by the body; `cursor` placeholder is removed and its offset returned as `DictationResult.cursorOffset` (the inserter moves the caret there in phase 4b — 4a only records it); `date` → today's date (medium style, current locale), `clipboard` → current pasteboard string, `app` → the app name; "Only in {app}" limits a snippet to a bundle id; the "Say 'snippet' before the trigger" toggle requires the spoken word "snippet" before the trigger.
5. **Dictionary → engine:** all dictionary words become `TranscriptionOptions.vocabulary` (max 64 words, most-used first — whisper's prompt budget); "Also fix it when I type it wrong" is stored (phase 4b/5 may use it) and shown, but no auto-correct runs in 4a. Uses counts increment when a word appears in a dictation's text (case-insensitive whole word).
6. **Contacts import** (MW-03c) is real: `ContactsImporting` protocol over `CNContactStore` — permission prompt, import first + last names as Name entries (source "contacts"), success/denied states, "updates when Contacts change" via `CNContactStoreDidChange` re-import; imported names are marked `source = contacts` and removed when the toggle turns off.
7. **Validation:** dictionary word duplicate = case-insensitive equality; snippet trigger must start with `/`, no spaces, unique (case-insensitive); suggestions `"/sig2"`, `"/work-sig"` pattern: append `2` and `-` + the first word of the body? Canvas shows `/sig2` and `/work-sig` — rule: `<trigger>2` and `/work-<trigger without slash>`.
8. **Re-style on History rows stays disabled** until phase 5 (it needs the LLM); the Styles page's live samples are the canvas's fixed strings (not computed).
9. **Filler list:** `um, uh, erm, hmm, like (only when surrounded by commas or followed by a pause marker), you know, I mean, sort of, kind of` — the canvas names "um, uh, like"; "like" is removed only in the pattern `, like,` / `like,` at a clause start to avoid eating the verb. Keep the list in one `FillerWords` constant with tests.

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated`.
- Pure logic (styler, expander, resolver, validation, suggestions) lives in the package with exhaustive tests; views hold no rules.
- Copy verbatim from the canvas (quoted per task). Design reference: `.superpowers/design/canvas.pdf` (run `scripts/render_design.sh` if missing); render tests (`VOXFLOW_RENDER=1`) per UI task; implementer + reviewer compare.
- Blocking storage off the main actor (same async wrapper pattern as `HistoryService`).
- No sleeps in tests. Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/111-phase4a-dictionary-snippets-styles` from `develop`; PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test` where the package changed; `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`.

---

### Task 1: Storage — `VoxFlowDatabase`, `dictionary`, `snippets`, `app_style_overrides`

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowStorage/VoxFlowDatabase.swift`, `DictionaryStore.swift`, `SnippetStore.swift`, `StyleOverrideStore.swift`, `Records.swift` (`DictionaryEntry`, `Snippet`, `StyleOverride`)
- Modify: `VoxFlowKit/Sources/VoxFlowStorage/DictationStore.swift` (build on `VoxFlowDatabase`; public API unchanged), `VoxFlowKit/Sources/VoxFlowCore/TextStyle.swift` (new: `TextStyle` enum — `formal, casual, veryCasual, verbatim`, `displayName` "Formal"/"Casual"/"Very casual"/"Verbatim", `rawValue` strings for storage)
- Test: `VoxFlowKit/Tests/VoxFlowStorageTests/DictionaryStoreTests.swift`, `SnippetStoreTests.swift`, `StyleOverrideStoreTests.swift`; existing `DictationStoreTests` stay green.

**Schema (migration `v2`):**
```sql
CREATE TABLE dictionary (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  word TEXT NOT NULL, word_folded TEXT NOT NULL UNIQUE,   -- lowercased, diacritic-insensitive
  sounds_like TEXT, type TEXT NOT NULL,                     -- name | term | product | place
  fix_typing BOOLEAN NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'user',                       -- user | contacts
  uses INTEGER NOT NULL DEFAULT 0, created_at DOUBLE NOT NULL);
CREATE TABLE snippets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trigger TEXT NOT NULL, trigger_folded TEXT NOT NULL UNIQUE,
  body TEXT NOT NULL, only_in_bundle_id TEXT, only_in_app_name TEXT,
  uses INTEGER NOT NULL DEFAULT 0, created_at DOUBLE NOT NULL);
CREATE TABLE app_style_overrides (
  bundle_id TEXT PRIMARY KEY, app_name TEXT NOT NULL, style TEXT NOT NULL);
```
Dictionary/snippet text is not encrypted (design: only dictation text is sensitive).

**Interfaces (all `Sendable` final classes over the shared queue; synchronous, blocking — app wrappers go async):**
- `VoxFlowDatabase(url:)` / `.inMemory()`: runs migrations; `queue: DatabaseQueue`.
- `DictionaryStore(database:)`: `insert(word:soundsLike:type:fixTyping:source:) throws -> DictionaryEntry` (throws `StorageError.duplicate(existing: DictionaryEntry)` when folded word exists), `update(_:)`, `delete(id:)`, `all() -> [DictionaryEntry]` (alphabetical), `find(word:) -> DictionaryEntry?` (folded), `removeAll(source: "contacts")`, `incrementUses(words: [String])` (folded match), `vocabulary(limit: Int) -> [String]` (most-used first, then alphabetical).
- `SnippetStore(database:)`: `insert(trigger:body:onlyIn: (bundleID, appName)?) throws -> Snippet` (`StorageError.duplicate`), `update`, `delete`, `all()` (by uses desc, then trigger), `find(trigger:)`, `incrementUses(id:)`.
- `StyleOverrideStore(database:)`: `set(bundleID:appName:style:)` (upsert), `remove(bundleID:)`, `all()` (by app name), `style(for bundleID:) -> TextStyle?`.
- `DictionaryEntry` (`id, word, soundsLike, type: DictionaryEntryType (name/term/product/place; displayName "Name"/"Term"/"Product"/"Place"), fixTyping, source, uses, createdAt`), `Snippet` (`id, trigger, body, onlyInBundleID, onlyInAppName, uses, createdAt`), `StyleOverride` (`bundleID, appName, style`).
- `DictationStore` gains `init(database:keyProvider:)`; the two existing convenience inits build a `VoxFlowDatabase` internally.

- [ ] **Step 1: Failing tests** — per store: insert/all ordering; duplicate detection case-insensitive and diacritic-insensitive ("Kubernetes" vs "kubernetes"; "Tāmaki" vs "Tamaki"); update; delete; `find`; `removeAll(source:)` keeps user entries; `incrementUses` folded whole words; `vocabulary(limit:)` ordering + limit; snippet trigger uniqueness; `onlyIn` round-trip; override upsert/remove/lookup; `DictationStoreTests` unchanged and green; a migration test: a v1 database file (create with the old schema SQL in the test) opens and gets the three tables.
- [ ] **Step 2–4:** implement; `swift test --filter VoxFlowStorageTests` then whole package.
- [ ] **Step 5: Commit** `feat(storage): dictionary, snippets and app style override tables on a shared database`

---

### Task 2: Styling — `TextStyler`, `RuleStyler`, `SnippetExpander`, `StyleResolver`

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowCore/Styling.swift` (`StylingOptions`, `TextStyler`, `StyledText`), `VoxFlowKit/Sources/VoxFlowStyling/FillerWords.swift`, `RuleStyler.swift`, `SnippetExpander.swift`, `StyleResolver.swift`; delete `StylingModule.swift` + its test.
- Test: `VoxFlowKit/Tests/VoxFlowStylingTests/{RuleStylerTests,SnippetExpanderTests,StyleResolverTests}.swift`

**Interfaces:**
- Core: `struct StylingOptions: Sendable, Equatable { style: TextStyle; removeFillers: Bool; autoPunctuate: Bool }`; `struct StyledText: Sendable, Equatable { text: String; fillersRemoved: Int; cursorOffset: Int? }`; `protocol TextStyler: Sendable { func style(_ raw: String, options: StylingOptions) -> StyledText }`.
- `FillerWords.patterns` (ruling 9) + `static func strip(_ text: String) -> (String, removed: Int)`.
- `RuleStyler: TextStyler` — pipeline: normalise whitespace → (removeFillers) strip → (autoPunctuate) sentence capitalisation + terminal period + standalone `i` → `I` + a space after `,.?!` → style: `formal` expands contractions from a fixed table (`can't→cannot, won't→will not, don't→do not, I'm→I am, it's→it is, we're→we are, you're→you are, that's→that is, let's→let us, gonna→going to, wanna→want to`) and replaces "push … to" phrasing? **No** (the canvas's Formal sample "Could we move the meeting…" is an LLM rewrite; rules do not attempt rewrites — document); `casual` = as is; `veryCasual` = lowercase everything except `I`? canvas: "can we push the meeting to thurs afternoon" → lowercase, no terminal period, `thursday→thurs` **not** attempted; `verbatim` = raw (ignores both toggles).
- `SnippetExpander(snippets: [SnippetRule], sayPrefix: Bool, context: (date: Date, clipboard: String?, appName: String?, bundleID: String?))` where `struct SnippetRule: Sendable, Equatable { trigger, body, onlyInBundleID }`; `func expand(_ text: String) -> (text: String, cursorOffset: Int?, used: [String])` — matches `/sig` or `slash sig` (case-insensitive, word boundaries), honours `sayPrefix` ("snippet slash sig"/"snippet /sig"), `onlyIn`, placeholders `cursor`/`date`/`clipboard`/`app` (as whole words in the body), returns used triggers for `incrementUses`.
- `StyleResolver.resolve(default: TextStyle, overrides: [String: TextStyle], bundleID: String?) -> TextStyle`.

- [ ] **Step 1: Failing tests** — fillers (each pattern; "like" rule both ways; count); punctuation/capitalisation cases ("i think so" → "I think so."; existing terminal `?` kept; double spaces); formal contractions; very casual lowercase without period; verbatim ignores toggles; expander: `/sig`, `slash sig`, `Slash Sig`, prefix required when `sayPrefix`, onlyIn mismatch → untouched, `cursor` offset computed after other placeholders, `date`/`clipboard`/`app`, multiple snippets, used list; resolver precedence.
- [ ] **Step 2–4:** implement; `swift test --filter VoxFlowStylingTests`.
- [ ] **Step 5: Commit** `feat(styling): rule styler, snippet expander and style resolver`

---

### Task 3: App wiring — `StylingSettings`, `StyledTranscriber`, dictionary vocabulary, content services

**Files:**
- Create: `VoxFlow/Styling/StylingSettings.swift` (`defaultStyle` "styling.default" = casual, `removeFillers` = true, `autoPunctuate` = true, `snippetSayPrefix` = false, `learnFromContacts` = false; snapshot box like `DictationSettingsBox`), `VoxFlow/Styling/StyledTranscriber.swift`, `VoxFlow/Content/ContentService.swift` (`@Observable @MainActor`; owns `VoxFlowDatabase` via `HistoryService`'s database — refactor `HistoryService` to expose `database: VoxFlowDatabase?` and open it once; async wrappers: `dictionary.all/insert/update/delete/find/removeAll(source:)/vocabulary`, `snippets.*`, `overrides.*`; `Sendable` snapshot boxes for the transcriber: `vocabularyBox: Mutex<[String]>`, `snippetsBox: Mutex<[SnippetRule]>`, `overridesBox: Mutex<[String: TextStyle]>`, refreshed after every write)
- Modify: `VoxFlow/Dictation/PreflightBuilder.swift` (records the frontmost app into a `Mutex<FrontmostApp?>` box the styled transcriber reads), `VoxFlow/Dictation/HistoryWriter.swift` (`style` from the result), `VoxFlowKit/Sources/VoxFlowDictation/DictationTranscribing.swift` (`DictationResult` gains `style: String?`, `cursorOffset: Int?`, `fillersRemoved: Int`), `VoxFlow/App/AppServices.swift`
- Test: `VoxFlowTests/StyledTranscriberTests.swift`, `VoxFlowTests/StylingSettingsTests.swift`, `VoxFlowTests/ContentServiceTests.swift`

**`StyledTranscriber: DictationTranscribing`** — `init(base:, styler: any TextStyler, settings: StylingSettingsBox, content: ContentSnapshots, frontmost: FrontmostBox, clipboard: @Sendable () -> String?, now: @Sendable () -> Date)`; `transcribe` forwards chunks/events to `base`, then: `style = StyleResolver.resolve(...)`, `styled = styler.style(result.rawText, options)`, `expanded = SnippetExpander(...).expand(styled.text)`, returns `DictationResult(text: expanded.text, rawText: result.rawText, …, style: style.rawValue, cursorOffset:, fillersRemoved:)`; fires `content.noteUses(words:snippets:)` (increment counters off-main). Vocabulary: `AppServices` builds `options: { var o = settingsBox.current.options; o.vocabulary = content.vocabularyBox.current; return o }`.

- [ ] **Step 1: Failing tests** — `StyledTranscriberTests` with `FakeDictationTranscriber` returning raw "um so can we push the meeting to thursday" → casual + fillers → "So can we push the meeting to thursday."; override for `com.apple.mail` → formal; verbatim passthrough; snippet expansion + used counters; `rawText` preserved; `style` string set. `ContentServiceTests` (temp database): CRUD via async wrappers; boxes refreshed after insert; `vocabulary` limited to 64. `StylingSettingsTests` defaults + persistence + hooks.
- [ ] **Step 2–4:** implement; app tests green; package tests green (result fields).
- [ ] **Step 5: Commit** `feat(app): styled transcriber, content service and dictionary vocabulary`

---

### Task 4: Dictionary page (MW-03, 03a, 03v, 03c, 03e)

**Files:** `VoxFlow/Content/Dictionary/{DictionaryViewModel,DictionaryPage,AddWordSheet,ContactsImport}.swift`, `VoxFlow/Content/Contacts/ContactsImporting.swift` (+ `CNContactStore` impl), tests `DictionaryViewModelTests`, `DictionaryRenderTests`; `MainWindow` routes `.dictionary`; `AppServices` builds the VM.

**Copy (verbatim):** intro "Names and terms VoxFlow should always get right. Add how they sound if the spelling isn't obvious."; button "+ Add word"; columns "Word · Sounds like · Type · Uses"; toggle "Learn names from Contacts" / "Reads first and last names locally. Nothing is uploaded."; sheet "Add word": Word, Sounds like (placeholder `optional — e.g. "pree-ya"`), Type (Name/Term/Product/Place), checkbox "Also fix it when I type it wrong", helper "Say it once to check: Hold fn and say the word", Cancel/Add; validation `"Kubernetes" is already in your dictionary.` + "Edit existing", Add disabled; Contacts states: "Importing 312 names… nothing is uploaded" / "312 names added · updates when Contacts change" / amber "Contacts access was denied. Allow it in System Settings → Privacy & Security → Contacts." + "Open System Settings" (toggle snaps back); empty: "Your dictionary is empty" / "Add names, products and jargon VoxFlow keeps mishearing. Or let it learn names from Contacts — locally." / "Add word" / "Import from Contacts".

**View model:** `entries`, `sheet: AddWordDraft?` (word, soundsLike, type, fixTyping; `validation: Validation?` (.duplicate(existing)/.empty) computed live; `canAdd`), `contacts: ContactsState` (.off, .importing, .done(count), .denied), actions `presentAdd()`, `add()`, `editExisting(entry)`, `delete(entry)`, `setLearnFromContacts(Bool)` (request permission → import → done; denied → state + toggle back to off), `openContactsSettings()`. `ContactsImporting`: `authorization() -> PermissionState`, `request() async -> PermissionState`, `fetchNames() async throws -> [String]` (first + last), change observation via a callback.

- [ ] Tests: add/duplicate/empty validation; edit existing prefills; delete; contacts flow with a fake (`granted` → entries with source contacts; `denied` → `.denied` and `learnFromContacts` false; toggle off removes contacts entries); render list/sheet/validation/contacts states/empty → compare with PDF page 4 (MW-03v), 8 (MW-03a), 4–5 (MW-03c), 9 (MW-03e).
- [ ] Commit `feat(app): Dictionary page with Add word sheet and Contacts import`

---

### Task 5: Snippets page (MW-04, 04a, 04v, 04e) and Styles page (MW-05, 05a)

**Files:** `VoxFlow/Content/Snippets/{SnippetsViewModel,SnippetsPage,NewSnippetSheet}.swift`, `VoxFlow/Content/Styles/{StylesViewModel,StylesPage,AddAppOverrideSheet}.swift`, tests + render tests; `MainWindow` routes; `AppServices` builds VMs.

**Snippets copy:** intro "Say a trigger and VoxFlow inserts the full text. Triggers work in every app."; "+ New snippet"; cards: trigger chip (monospace), "Used 84×", 3-line body preview; toggle `Say "snippet" before the trigger` / "Avoids accidental expansion when a trigger word appears in normal speech."; sheet "New snippet": Say (monospace) + hint `spoken as "slash standup"` (derived from the trigger), Insert (multiline; `cursor` chip), helper "Insert cursor where dictation should continue. Placeholders: date, clipboard, app.", checkbox "Only in {app}" (app picker via `InstalledAppsProviding`), Cancel/Save; validation `/sig is already used by "Email signature".` — the canvas names the snippet by a title we don't store: ruling — use the existing snippet's first body line, quoted; suggestion "Triggers start with / and contain no spaces. Try /sig2 or /work-sig."; empty: "No snippets" / "Say a short trigger, get a full block of text. Start with a signature." / "Create /sig" (prefills).

**Styles copy:** intro "Choose how VoxFlow cleans up what you say. Same words in, different text out — all rewritten by the on-device model."; "You said:" "um so yeah can we uh push the meeting to like thursday afternoon"; cards Formal ("Could we move the meeting to Thursday afternoon?" / "Full sentences, no contractions. Good for Mail and documents."), Casual ("Can we push the meeting to Thursday afternoon?" / "Your voice, tidied up. Fillers removed, punctuation added."), Very casual ("can we push the meeting to thurs afternoon" / "Lowercase, light touch. Feels like a quick text."); "Per-app overrides" + "+ Add app"; rows app + style picker (Formal/Casual/Very casual/"Verbatim (no cleanup)"); toggles "Remove filler words (um, uh, like)", "Auto-punctuate and capitalize"; sheet "Add app override": search "Search installed apps", list (name + hint), "Style in {app}" picker, Cancel/Add.

- [ ] Tests: snippet validation (`/` prefix, spaces, duplicate with the quoted first line, suggestions `/sig2` `/work-sig`), spoken hint derivation, create-prefilled `/sig`, only-in; styles: default selection persists, override add/remove/change, toggles persist, resolver used for the History meta (style names). Renders vs PDF pages 8–9 (MW-04a/MW-05a), 4 (MW-04v), 9 (MW-04e), and the 1c text for MW-05.
- [ ] Commit `feat(app): Snippets and Styles pages with per-app overrides`

---

### Task 6: Wiring check, docs, PR

- `README.md`/`CHANGELOG.md` (Unreleased on develop: 2.2.0 line items), ADR-005 "Rule-based styling pipeline and where the LLM plugs in" (TextStyler seam, snippet expansion order, override precedence, vocabulary budget 64).
- Full verification; manual checklist for the owner (see below).
- PR into `develop`: `Part of #111.`; follow-ups for anything deferred (cursor placement in the inserter, "fix it when I type it wrong").

**Manual checklist for the owner:**

1. Dictionary page: add a word → hold fn and dictate it → the word is recognised (not
   mis-heard).
2. Snippets page: create a snippet with trigger `/sig` → hold fn and say "slash sig" →
   the body is expanded into the dictated text.
3. Styles page: set the Mail override to Formal → hold fn and dictate into Mail →
   contractions are expanded (e.g. "can't" → "cannot").
4. History page: expand a row from one of the dictations above → the style used is
   shown in the row's meta.
5. Dictionary page: turn on "Learn names from Contacts" → grant the Contacts
   permission prompt → names are imported (and denying it snaps the toggle back off).
6. Snippets page: turn on "Say 'snippet' before the trigger" for a snippet → dictating
   the trigger alone does *not* expand it, but saying "snippet slash sig" does.

## Self-review
- Coverage: §5 tables (T1); MW-03* (T4); MW-04*, MW-05* (T5); styling + overrides + vocabulary in the dictation path (T2, T3). Deferred: caret placement for `cursor` (4b), auto-correct typing, Re-style (5), Home/General/MCP/menu bar/notifications (4b).
- Consistency: `TextStyle` (Core) used by storage, styling, app; `SnippetRule`/`StylingOptions`/`StyledText` shared; `DictationResult` new fields consumed by `HistoryWriter` and the styled transcriber; `ContentService` boxes consumed by `StyledTranscriber`.
