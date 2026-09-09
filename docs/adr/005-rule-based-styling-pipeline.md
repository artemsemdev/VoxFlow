# ADR-005: Rule-based styling pipeline and where the LLM plugs in

Status: Accepted · Date: 2026-09-09

## Context

The design (canvas MW-05, "Styles") asks for four rewrite tones — Formal, Casual, Very
casual, Verbatim — plus two global toggles under them (remove filler words, auto-punctuate
and capitalize), and for snippets that expand inside the styled text. Phase 5 replaces the
tone rewrite with an on-device LLM; phase 4a has no model yet and needs a deterministic
stand-in that behaves the same way from the caller's side, so the swap in phase 5 does not
ripple through storage, History or the dictation path.

## Decision

- `TextStyler` (`VoxFlowCore`) is the seam: `func style(_ raw: String, options: StylingOptions)
  -> StyledText`. `StylingOptions` carries the target `TextStyle` plus the two global toggles
  (`removeFillers`, `autoPunctuate`); `StyledText` carries the styled text, how many filler
  occurrences were removed, and an optional `cursorOffset`. Phase 4a's only implementation is
  `RuleStyler` (`VoxFlowStyling`); phase 5 adds an LLM-backed styler behind the same protocol —
  no other layer (storage, `StyledTranscriber`, History) needs to change.
- `RuleStyler` pipeline order: normalise whitespace → (if `removeFillers`) strip fillers
  (`FillerWords`) → (if `autoPunctuate`) sentence capitalisation, terminal period, standalone
  `i` → `I`, a space after `,.?!` → apply the style. `Verbatim` short-circuits the whole
  pipeline and returns the raw text unchanged, ignoring both toggles.
- `SnippetExpander` runs *after* styling, over the already-styled text — a trigger typed as
  `/sig` or spoken as `slash sig` (case-insensitive, whole word) expands to its body. Body
  placeholders are whole-word, case-insensitive: `date` → today's date (medium style, current
  locale), `clipboard` → the current pasteboard string, `app` → the frontmost app's name,
  `cursor` → removed from the body, its position recorded as `DictationResult.cursorOffset`
  (the phase-4b inserter moves the caret there; 4a only records it — see Consequences). "Only
  in {app}" scopes a snippet to a bundle id; unmatched snippets are left untouched in the text.
  The "Say 'snippet' before the trigger" toggle requires the spoken word "snippet" immediately
  before the trigger to count as a match.
- `StyleResolver.resolve(default:overrides:bundleID:)` — precedence is override > default: a
  per-app override (keyed by bundle id, `app_style_overrides`) wins when one exists for the
  frontmost app; otherwise the global default style applies (Casual out of the box).
- Styling runs in the app layer, not in the engine: `StyledTranscriber` decorates the base
  `DictationTranscribing` and, once the base transcriber returns, resolves the style for the
  app captured at fn-down, runs `RuleStyler`, then `SnippetExpander`. `DictationResult.rawText`
  stays exactly what the speech engine produced; `text` is the styled-and-expanded output.
  Partial `DictationEvent`s forwarded during capture stay raw — only the final result is
  styled. History stores both `text` and `rawText`, plus the resolved style's name.
- Dictionary words feed the engine, not the styler: every `dictionary` row's `word` is a
  candidate for `TranscriptionOptions.vocabulary`, capped at the 64 most-used words (falling
  back to alphabetical) — whisper's prompt has a limited budget, so `DictionaryStore.vocabulary
  (limit:)` does the ranking in SQL rather than handing the whole table to the engine.

## Consequences

- Phase 5's LLM replaces only the rewrite step behind `TextStyler`; fillers and
  auto-punctuation stay rule-based global toggles either way, and `SnippetExpander` /
  `StyleResolver` are unaffected by the swap.
- The rules never attempt semantic rewrites. Formal only expands a fixed contraction table
  (`can't → cannot`, `it's → it is`, …); it does not restructure a sentence the way the
  canvas's Formal sample implies ("Could we move the meeting…" is what the phase-5 LLM
  produces, not what `RuleStyler` produces from the same input).
- The "like" filler rule is narrow by design — it only removes `like` set off by commas (`,
  like,`) or opening a clause followed by a comma, so "I like this" or "it's like a demo" are
  left alone. A broader rule would eat the verb "to like" and the preposition "like" too often
  to be safe as a blind regex.
- `cursorOffset` is computed and returned in 4a but nothing consumes it yet — the Accessibility
  inserter does not move the caret. Caret placement for the `cursor` snippet placeholder is
  deferred to phase 4b.
- `dictionary`, `snippets` and `app_style_overrides` live in the same SQLite file as dictation
  history (`VoxFlowDatabase`, one `DatabaseQueue`) but are not encrypted — only dictation text
  is sensitive (ADR-004); words, snippet bodies and per-app style choices are not.
