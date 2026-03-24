# Phase 2: Repeat-Use Features

Derived from [ROADMAP.md](./ROADMAP.md). This phase reduces manual setup and produces outputs that are useful after the first run.

## Goal

Make repeated transcription runs faster to configure and easier to reuse.

## What To Implement

### 1. Presets

Add a small preset system as data, not hard-coded UI branches.

Keep the first set small:

- Interview (optimized for two speakers, conversational pace)
- Meeting (optimized for multiple speakers, variable audio quality)
- Lecture (optimized for long-form single speaker)

Preset data format:

- JSON files in a known directory (e.g., `presets/` inside app support)
- each preset is a partial config overlay merged onto the base config
- schema: `{ "name": string, "description": string, "settings": { partial TranscriptionOptions } }`
- user-created presets use the same format

Rules:

- presets must be inspectable (user can view the full resolved config)
- user overrides must still work and take precedence over preset values
- final effective settings must be visible in run metadata
- desktop UI must include preset selection in the transcription flow
- preset create/edit/delete in settings (simple form, not a template editor)

### 2. Structured Outputs

Keep the existing text output. Add only the extra formats that are actually needed.

Suggested first additions:

- JSON
- Markdown
- SRT or VTT only if there is a clear use case

Rules:

- one shared transcript model feeds all writers
- structured formats need versioned schemas
- plain text remains supported

### 3. Run Metadata

Write a sidecar file for each run.

Include:

- run id
- timestamp
- model
- language
- warnings
- accepted/skipped counts
- output file list
- effective config or preset

### 4. Bundle Layout

Save run artifacts in a predictable folder structure.

Example:

```text
run-id/
  transcript.txt
  transcript.json
  metadata.json
  config.snapshot.json
```

### 5. Batch Improvements

Improve repeated folder processing without inventing a job system.

Required:

- deterministic output names
- clear batch summary
- easy rerun for failed files only

Desktop batch UI (excluded from Phase 1, required in Phase 2):

- folder picker for batch input
- batch progress with per-file status
- batch summary view with pass/fail per file
- rerun failed files action

### 6. Transcript Workspace

Keep the desktop workspace simple. This is a viewer, not an editor.

Required:

- list of recent runs (stored in a local index file, not a database)
- open a run's transcript
- copy transcript text to clipboard
- open output folder
- view run metadata and warnings

Explicitly not included:

- full-text search across all transcripts (too large for this phase)
- transcript editing or annotation
- tagging or categorization

### 7. Auto-Update

Desktop users need a way to receive updates without re-downloading manually.

Required:

- check for new version on launch (or on demand)
- notify user of available update with release notes summary
- download and apply update, or link to download page

Implementation options (pick one):

- Sparkle framework (standard for macOS apps)
- custom check against GitHub releases API

Rules:

- update check must not send telemetry or usage data
- user must be able to disable auto-check in settings
- update must not interrupt an active transcription

## Out of Scope

- Full editor
- Plugin system
- Generic AI orchestration
- Speaker diarization
- Large preset catalog

## Implementation Order

1. Define preset schema and merge rules.
2. Add structured output writers.
3. Add metadata sidecar.
4. Define bundle folder layout.
5. Build batch desktop UI (folder picker, progress, summary, rerun).
6. Improve batch summary and rerun support in the shared core.
7. Build the transcript workspace (recent runs list, viewer, metadata).
8. Add auto-update check mechanism.
9. Update docs for new features (presets, outputs, batch UI, workspace).

## Practical Risks

- Presets will become magic if users cannot inspect them.
- Too many formats will create maintenance cost.
- Workspace scope will grow unless it is strictly limited to viewing and copying — no editing, no search indexing, no tagging.
- Auto-update introduces a network call, which conflicts with the local-only principle. Mitigate by making it opt-in and ensuring it contacts only the project's own release endpoint.
- Batch desktop UI can become complex if it tries to show real-time per-file progress. Keep it simple: a list with status icons.

## Done When

- repeated runs need less manual configuration
- outputs are reusable without extra manual cleanup
- batch runs have a desktop UI
- batch reruns are simpler
- the desktop workspace helps inspect results without turning into an editor
- users are notified of available updates
