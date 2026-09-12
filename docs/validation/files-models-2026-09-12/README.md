# Files and Models visual evidence — issue 141

**Files/Models visual review approved within the documented scope and platform limits. The final integrated native run passed its complete text and structured warning gate.**

This package compares real production-view captures with the authoritative [design canvas](../../../design/VoxFlow.dc.html). Original PNGs are preserved; contact sheets only add labels and proportional placement. `manifest.json` records every original path and SHA-256. Open the original images for full-size text inspection.

| Step | Surface and states | Review outcome |
| --- | --- | --- |
| 1 | Files: empty drop area, live drag overlay, duplicate drops, queued/running/done rows | Clear entry point and state-specific actions; neutral queued rail and green completed rail agree with the canvas. Download/transcription progress appears gray in inactive native captures, so active-window blue appearance is not established by these images. |
| 2 | Files controls: TXT, SRT, VTT, JSON, Markdown, language, batch mode, timestamps, Save to, missing model | Labels and operations are present. The existing approved bottom-toolbar arrangement is retained instead of the canvas side panel. Timed formats disable redundant timestamp control. |
| 3 | Results: header, all five formats, cleanup and three segment lengths | Header retains the filename extension and fits the intended compact height. TXT/JSON/Markdown now show actual output text; SRT/VTT retain cue columns and correct timecode punctuation. Settled final captures show all three cue texts aligned, with no overlap. |
| 4 | Results: search, no matches, Copy/Save/export footer and export failure | Search affects the displayed segments only. No-match Markdown retains document metadata while showing no segment text. Export failure remains visible in the footer. Saved/reveal and additional-format actions remain available when applicable. |
| 5 | Models: catalog, not installed, installed/default, downloading, paused, verifying and first load; light/dark | Controls distinguish Download/Pause/Resume/Remove and loading phases. Settled paused rows show the catalog subtitle and Resume; the earlier transfer-total caption was a stale capture, not a product defect. Production supports Whisper small/turbo and Qwen2.5; unsupported canvas Parakeet is excluded. Qwen uses its real 2.1 GB descriptor rather than the canvas's 1.9 GB example. |
| 6 | Errors: corrupt/unsupported input, checksum mismatch, insufficient space, download failure and offline variants | Recovery actions and diagnostic copy are explicit. Corrupt input has Retry/Remove; unsupported input has Remove. Checksum failure uses an inline red row and Retry download. Real temporary model paths and mock byte counts are fixture data. |
| 7 | Confirmations: stop transcription, long audio, model removal, only-model guard, quit while active | Native macOS sheets preserve the intended copy/actions and destructive roles. System sheet geometry differs from the canvas icon/vertical-button sketches; inactive button coloration is not evidence of keyboard/default-action behavior. The displayed SYS-QUIT capture includes 72% progress and about 3 min left, with all three actions. |
| 8 | Shipped app icon | A preserved true before image shows the generic placeholder; a fresh application-URL after capture shows the source four-bar mark. Bundled asset capture is independently included in the final matrix. |

## Comparisons and provenance

- `source/`: source canvas runtime renders supplied by the current audit. These are design references, not historical native screenshots.
- `before/`: preserved historical native images plus a fresh reproduction of production commit `22ef383ec8893c5edd3950f92e4cc12ff959e04e`. The reproduction changes **only** `NativeRenderHost.swift` and `FilesModelsAuditRenderTests.swift`: all ordinary content snapshots await native layout, and the historical helper keeps their windows unordered; actual alerts still use ordered sheet parents. Production behavior remains historical. The existing true icon-before image predates the icon change; commit 22ef383 already includes the new icon. The original broad historical run passed 11 tests in six suites; the final settled Files/Models recapture passed 10 tests across two iterations. Both complete text and structured warning checks passed. Its exact compressed fixture-only patch and compressed validation logs are in `validation/`.
- `after/`: final integrated production captures at `7a17996`, from the accepted full native run. All Files/Models and Quit fixtures pass, and the complete run is warning-clean.
- `contact-sheets/`: source/native overviews, formats, model states, alerts, queue/loading and the genuine icon before/after pair. All 54 matching native states have independently captured before/after pairs; see `pair-inventory.md`. Unchanged states are labeled unchanged; source/native references are separate from chronological before/after.

## Limits

These are deterministic fake-backed native component fixtures, not screenshots of the owner's private files or model store. They establish visible copy, geometry and state presentation. They do not establish screen-reader order, keyboard focus, contrast ratios, hover/animation behavior, real downloads, model accuracy or actual Finder/export access. No claim of full accessibility compliance or exact whole-window pixel parity is made.

Known intentional differences are the approved bottom toolbar, supported production catalog and byte sizes, native macOS sheet layout, and safer non-default destructive removal. Those decisions are distinct from unresolved screenshot artifacts.

## Validation and approval

The original broad historical run passed 11 tests in six render suites; the final settled historical subset passed 10 tests across two iterations. The final current native-action fixture correction passed Files/Models and Quit twice: 12 tests with clean complete text and structured warning checks.

The final integrated commit `7a17996e93edd550a5ab8e97559e33a368434881` passed 1,360 structured cases with five intentional opt-in skips. The real local LLM rewrite test executed with the model override enabled; this was not a guard-return pass. Production UI/release commit is `6172012`; the later changes only correct native test lifecycle. The [complete native log](validation/voxflow-completion-delivery.log.gz) and [structured xcresult report](validation/voxflow-completion-delivery.xcresult.json.gz) pass the warning gate; their hashes are in the manifest. Earlier failed lifecycle experiments are not final after-image evidence.

The independent visual review found no blocking Files/Models layout or copy defect in these settled captures. Approval remains qualified by the native platform differences and screenshot-only limits above.

## Browse the evidence

Open [the visual index](index.html) for all contact sheets and full-resolution originals, or [the pair inventory](pair-inventory.md) for the complete 54-state checklist. The manifest records original paths and hashes; historical production and test-fixture provenance are separate.

- [Source versus native surfaces](contact-sheets/01-source-and-native.png)
- [Result header and TXT before/after](contact-sheets/02-results.png)
- [All output formats and search](contact-sheets/03-result-formats.png)
- [Light/dark Models states](contact-sheets/04-model-states.png)
- [All Files/Models native alerts](contact-sheets/05-alerts.png)
- [Queue and loading states](contact-sheets/06-queue-and-loading.png)
- [True icon before/after](contact-sheets/07-icon.png)
- [Quit and corrupt-input source comparison](contact-sheets/08-quit-and-corrupt.png)

The five `pairs-changed-results-*` sheets cover all result/header changes. Fourteen `pairs-unchanged-states-*` sheets explicitly pair states with unchanged production presentation; 37 pairs are byte-identical. Other unchanged-state differences reflect temporary paths or native progress/capture frames; inspect the original pairs rather than inferring a production change from unequal hashes.
