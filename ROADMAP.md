# Roadmap: Batch Processing

## Overview

Extend the Audio Transcription Utility to support processing multiple audio files in a single run. The application currently processes exactly one `.m4a` file per invocation. Batch processing adds the ability to discover, queue, and transcribe multiple files from an input directory, producing one result file per input file.

> **Scope change:** The PRD (`PRD.md`, Non-Goals) currently lists "Batch folder processing" as out of scope. Implementing this feature requires updating the PRD to move batch processing from Non-Goals into Functional Requirements.

---

## Goals

- Process all `.m4a` files in a configured input directory in a single application run
- Produce one result `.txt` file per input file, preserving the existing output format
- Reuse the Whisper model and factory across all files in a batch (aligned with ADR-010)
- Report batch-level progress (file X of Y) alongside per-file progress
- Support graceful cancellation that stops the batch without corrupting completed results
- Continue processing remaining files when a single file fails (configurable)
- Generate a batch summary report at the end of the run

## Non-Goals (for this iteration)

- Parallel/concurrent file processing (files are processed sequentially)
- Recursive subdirectory scanning
- CLI argument parsing (all behavior remains configuration-driven)
- Watch mode / file system monitoring
- Merging results from multiple files into a single output file
- Web UI or REST API for batch management

---

## Architecture Decisions

### BATCH-ADR-001: Sequential file processing

- **Context:** Whisper inference is CPU/GPU-intensive. Parallel processing would require careful memory management and native runtime coordination.
- **Decision:** Process files sequentially in a single thread. The Whisper factory and model are shared across files.
- **Consequences:** Simpler implementation. Predictable memory usage. No native runtime contention. Throughput scales linearly with file count.

### BATCH-ADR-002: Configuration-driven batch mode

- **Context:** The application is fully configuration-driven (ADR-003). Batch mode should follow the same pattern rather than introducing CLI arguments.
- **Decision:** Add a `processingMode` field and a `batch` section inside the `transcription` configuration. When `processingMode` is `"batch"`, the application discovers files from `batch.inputDirectory` instead of using the single `inputFilePath`. Single-file paths are optional in batch mode.
- **Consequences:** No CLI contract changes. The user's intent is explicit. Backward-compatible — when `processingMode` is `"single"` or absent, the application behaves exactly as before.

### BATCH-ADR-003: One result file per input file

- **Context:** The current output contract is one `result.txt` per run. For batch mode, combining all results would lose file boundaries.
- **Decision:** Each input file produces its own result file in `batch.outputDirectory`, named `{inputFileNameWithoutExtension}.txt`.
- **Consequences:** Existing output format is preserved per file. Results are independently usable. The single-file `resultFilePath` setting is ignored when batch mode is active.

### BATCH-ADR-004: Continue-on-error with summary

- **Context:** A batch of 50 files should not abort entirely because file #3 has a corrupt header.
- **Decision:** By default, record the error and continue to the next file. Configurable via `batch.stopOnFirstError`.
- **Consequences:** Users get maximum output from a batch run. The summary report clearly shows which files succeeded, failed, or were skipped.

### BATCH-ADR-005: Intermediate WAV files use a temp directory

- **Context:** In single-file mode, `wavFilePath` is a fixed configured path. In batch mode, each file needs its own WAV.
- **Decision:** Generate intermediate WAV files in `batch.tempDirectory` (defaults to system temp). Clean up after each file completes unless `batch.keepIntermediateFiles` is `true`.
- **Consequences:** Disk usage stays bounded. Debugging is possible by enabling `keepIntermediateFiles`.

---

## Configuration Schema

The processing mode and batch settings are configured inside the `transcription` section of `appsettings.json`:

```json
{
  "transcription": {
    "processingMode": "single",

    "inputFilePath": "artifacts/input.m4a",
    "wavFilePath": "artifacts/output.wav",
    "resultFilePath": "artifacts/result.txt",

    "batch": {
      "inputDirectory": "artifacts/input",
      "outputDirectory": "artifacts/output",
      "tempDirectory": "",
      "filePattern": "*.m4a",
      "stopOnFirstError": false,
      "keepIntermediateFiles": false,
      "summaryFilePath": "artifacts/batch-summary.txt"
    },

    "...other existing settings..."
  }
}
```

| Setting                      | Type     | Default                        | Description                                                    |
|------------------------------|----------|--------------------------------|----------------------------------------------------------------|
| `processingMode`             | `string` | `"single"`                     | `"single"` for one file, `"batch"` for directory processing.  |
| `batch.inputDirectory`       | `string` | required when mode is `batch`  | Directory to scan for input audio files.                       |
| `batch.outputDirectory`      | `string` | required when mode is `batch`  | Directory where per-file result `.txt` files are written.      |
| `batch.tempDirectory`        | `string` | system temp                    | Directory for intermediate `.wav` files.                       |
| `batch.filePattern`          | `string` | `"*.m4a"`                      | Glob pattern for file discovery.                               |
| `batch.stopOnFirstError`     | `bool`   | `false`                        | Stop the entire batch on the first file failure.               |
| `batch.keepIntermediateFiles` | `bool`   | `false`                        | Retain intermediate `.wav` files after processing.             |
| `batch.summaryFilePath`      | `string` | `"batch-summary.txt"`          | Path for the batch completion summary report.                  |

When `processingMode` is `"single"` or absent, single-file paths (`inputFilePath`, `wavFilePath`, `resultFilePath`) are required and the `batch` section is ignored. When `processingMode` is `"batch"`, single-file paths are optional and the `batch` section is required.

---

## Implementation Plan

### Phase 1: Foundation (Configuration and File Discovery)

#### Task 1.1: Add batch configuration model
- **File:** `Configuration/TranscriptionOptions.cs`
- **What:** Add `BatchConfiguration` class for JSON deserialization and `BatchOptions` record for validated runtime options.
- **Validation rules:**
  - When `processingMode` is `"batch"`: `batch.inputDirectory` and `batch.outputDirectory` are required and must be non-empty.
  - `filePattern` must be non-empty (defaults to `*.m4a`).
  - `tempDirectory` defaults to `Path.GetTempPath()` when empty.
  - `summaryFilePath` must be non-empty.
- **Wire into:** `TranscriptionSettingsRoot` and `TranscriptionOptions`.
- **Backward-compatible:** When `processingMode` is `"single"` or absent, existing behavior is unchanged.

#### Task 1.2: Add file discovery service
- **File:** `Services/FileDiscoveryService.cs` (new)
- **What:** Static class with method `DiscoverInputFiles(BatchOptions options, CancellationToken ct)`.
- **Behavior:**
  - Scan `inputDirectory` for files matching `filePattern` (non-recursive).
  - Sort files alphabetically for deterministic ordering.
  - Return `IReadOnlyList<DiscoveredFile>` where `DiscoveredFile` is a record containing `InputPath`, `OutputPath`, `TempWavPath`.
  - Compute output path as `{outputDirectory}/{fileNameWithoutExtension}.txt`.
  - Compute temp WAV path as `{tempDirectory}/{fileNameWithoutExtension}_{guid}.wav`.
  - Throw if no files are found.

#### Task 1.3: Add batch startup validation
- **File:** `Services/StartupValidationService.cs`
- **What:** Add batch-specific checks alongside existing checks.
- **New checks (when batch mode is active):**
  - `inputDirectory` exists.
  - `outputDirectory` exists and is writable.
  - `tempDirectory` exists and is writable.
  - At least one file matches `filePattern` in `inputDirectory`.
- **Existing checks modified:**
  - Skip `CheckInputFile` for single `inputFilePath` (not used in batch mode).
  - Reuse all other checks (ffmpeg, model, languages, Whisper runtime).

### Phase 2: Core Batch Orchestration

#### Task 2.1: Extract single-file pipeline into a reusable method
- **File:** `Program.cs`
- **What:** Extract the current transcription pipeline (convert → load model → load WAV → select language → write output) into a static method:
  ```csharp
  private static async Task<FileProcessingResult> ProcessSingleFileAsync(
      string inputPath,
      string wavPath,
      string outputPath,
      WhisperFactory whisperFactory,
      TranscriptionOptions options,
      CancellationToken cancellationToken)
  ```
- **Return type:** `FileProcessingResult` record with `InputPath`, `OutputPath`, `Status` (Success/Failed/Skipped), `ErrorMessage?`, `Duration`, `DetectedLanguage`.
- **Key:** This method does NOT create the `WhisperFactory` — it receives it as a parameter (factory is shared across the batch).

#### Task 2.2: Implement batch orchestration loop
- **File:** `Program.cs`
- **What:** Add a batch execution path in `Main()`:
  ```
  if processingMode == "batch":
      1. Run batch startup validation
      2. Create WhisperFactory once (shared)
      3. Discover input files
      4. For each discovered file:
          a. Print "Processing file X of Y: {fileName}"
          b. Call ProcessSingleFileAsync
          c. Record result
          d. Clean up temp WAV (unless keepIntermediateFiles)
          e. If failed and stopOnFirstError → break
      5. Write batch summary
      6. Print summary to console
      7. Return exit code (0 if all succeeded, 1 if any failed)
  else:
      existing single-file flow (unchanged)
  ```

#### Task 2.3: Implement batch summary writer
- **File:** `Services/BatchSummaryWriter.cs` (new)
- **What:** Static class that writes a human-readable summary report.
- **Summary format:**
  ```
  Batch Processing Summary
  ========================
  Total files:     10
  Succeeded:       8
  Failed:          1
  Skipped:         1
  Total duration:  00:05:32

  Results:
  [OK]      recording1.m4a → recording1.txt (English, 00:00:45)
  [OK]      recording2.m4a → recording2.txt (Russian, 00:01:12)
  [FAILED]  recording3.m4a — Conversion failed: ffmpeg exit code 1
  [SKIPPED] recording4.m4a — File is empty (0 bytes)
  ...
  ```

### Phase 3: Progress Reporting

#### Task 3.1: Extend progress service for batch context
- **File:** `Services/ConsoleProgressService.cs`
- **What:** Add batch-level context to the progress display.
- **New information shown:**
  - `[File 3/10]` prefix before per-file progress.
  - Current file name.
  - Batch elapsed time.
- **Implementation:** Add a `SetBatchContext(int fileIndex, int totalFiles, string fileName)` method. When batch context is set, the progress line includes the batch prefix.
- **Single-file mode:** When no batch context is set, behavior is identical to current.

### Phase 4: Error Handling and Cleanup

#### Task 4.1: Per-file error isolation
- **File:** `Program.cs` (batch loop)
- **What:** Wrap each `ProcessSingleFileAsync` call in a try/catch that:
  - Catches `OperationCanceledException` → propagate (user cancelled the batch).
  - Catches all other exceptions → record as failed, continue to next file (unless `stopOnFirstError`).
  - Ensures temp WAV is cleaned up even on failure.

#### Task 4.2: File-level pre-validation
- **File:** `Services/FileDiscoveryService.cs`
- **What:** During discovery, mark files as `Skipped` if:
  - File size is 0 bytes.
  - File is not readable (permission check).
- **Consequence:** Skipped files appear in the summary but are never processed.

### Phase 5: Testing

#### Task 5.1: Unit tests for batch configuration
- **File:** `tests/WisperTestApp.UnitTests/BatchConfigurationTests.cs` (new)
- **Tests:**
  - Default `processingMode` → `IsBatchMode` is `false`, batch section is ignored.
  - Batch enabled without `inputDirectory` → throws validation error.
  - Batch enabled without `outputDirectory` → throws validation error.
  - Valid batch config → all options populated correctly.
  - Default values applied when optional fields are missing.

#### Task 5.2: Unit tests for file discovery
- **File:** `tests/WisperTestApp.UnitTests/FileDiscoveryServiceTests.cs` (new)
- **Tests:**
  - Directory with matching files → returns sorted list.
  - Directory with no matching files → throws.
  - Empty files are marked as skipped.
  - Output and temp paths are generated correctly.
  - Custom file pattern filters correctly.

#### Task 5.3: Unit tests for batch summary
- **File:** `tests/WisperTestApp.UnitTests/BatchSummaryWriterTests.cs` (new)
- **Tests:**
  - All succeeded → summary shows correct counts.
  - Mixed results → summary shows correct counts and per-file status.
  - Empty batch → summary handles edge case.

#### Task 5.4: End-to-end batch tests
- **File:** `tests/WisperTestApp.EndToEndTests/BatchProcessingTests.cs` (new)
- **Tests:**
  - Batch mode disabled → single-file behavior unchanged.
  - Batch mode with valid directory → processes all files.
  - Batch mode with missing directory → startup validation fails.
  - Batch mode with `stopOnFirstError` → stops after first failure.

### Phase 6: Documentation

#### Task 6.1: Update PRD.md
- Move "Batch folder processing" from Non-Goals to Functional Requirements.
- Add functional requirements section for batch processing.

#### Task 6.2: Update ARCHITECTURE.md
- Add batch ADRs.
- Update runtime flow diagram to show batch branching.
- Add batch-related components to the component view.

#### Task 6.3: Update README.md
- Add batch configuration example.
- Add usage instructions for batch mode.

#### Task 6.4: Update appsettings.example.json
- Add the `batch` section with example values.

---

## File Change Summary

| File                                         | Action   | Description                                        |
|----------------------------------------------|----------|----------------------------------------------------|
| `Configuration/TranscriptionOptions.cs`      | Modify   | Add `BatchConfiguration`, `BatchOptions`, wiring   |
| `Program.cs`                                 | Modify   | Extract single-file method, add batch loop          |
| `Services/FileDiscoveryService.cs`           | New      | File discovery and path generation                  |
| `Services/BatchSummaryWriter.cs`             | New      | Batch summary report generation                     |
| `Services/ConsoleProgressService.cs`         | Modify   | Add batch context to progress display               |
| `Services/StartupValidationService.cs`       | Modify   | Add batch-specific validation checks                |
| `appsettings.json`                           | Modify   | Add `batch` section (disabled by default)           |
| `appsettings.example.json`                   | Modify   | Add `batch` section with example values             |
| `PRD.md`                                     | Modify   | Move batch to Functional Requirements               |
| `ARCHITECTURE.md`                            | Modify   | Add batch ADRs and updated diagrams                 |
| `README.md`                                  | Modify   | Add batch usage documentation                       |
| `tests/.../BatchConfigurationTests.cs`       | New      | Batch config validation tests                       |
| `tests/.../FileDiscoveryServiceTests.cs`     | New      | File discovery tests                                |
| `tests/.../BatchSummaryWriterTests.cs`       | New      | Summary report tests                                |
| `tests/.../BatchProcessingTests.cs`          | New      | End-to-end batch tests                              |

---

## Implementation Order and Dependencies

```
Phase 1 (Foundation)
  Task 1.1 (Config) ─────────┐
  Task 1.2 (Discovery) ──────┤
  Task 1.3 (Validation) ─────┘
          │
Phase 2 (Orchestration)
  Task 2.1 (Extract method) ─┐
  Task 2.2 (Batch loop) ─────┤ depends on Phase 1
  Task 2.3 (Summary writer) ─┘
          │
Phase 3 (Progress)
  Task 3.1 (Batch progress) ── depends on Phase 2
          │
Phase 4 (Error Handling)
  Task 4.1 (Error isolation) ─┐ depends on Phase 2
  Task 4.2 (Pre-validation) ──┘
          │
Phase 5 (Testing)
  Tasks 5.1-5.4 ─────────────── depends on Phases 1-4
          │
Phase 6 (Documentation)
  Tasks 6.1-6.4 ─────────────── depends on Phases 1-5
```

---

## Risks and Mitigations

| Risk                                              | Mitigation                                                         |
|---------------------------------------------------|--------------------------------------------------------------------|
| Memory growth across many files                   | Process files sequentially; load/unload WAV samples per file       |
| Native Whisper runtime instability across files    | Reuse factory (ADR-010); do not dispose/recreate between files     |
| Disk space from intermediate WAV files             | Clean up after each file; configurable `keepIntermediateFiles`     |
| Output file name collisions                        | Use deterministic naming `{stem}.txt`; fail if output already exists |
| Long batch runs with no visibility                 | Batch progress reporting; per-file status output                   |
| Configuration complexity                           | Batch section is optional; disabled by default; clear defaults     |

---

## Success Criteria

- Single-file mode works identically when `processingMode` is `"single"` or absent
- All `.m4a` files in `inputDirectory` are discovered and processed
- Each file produces an independent result `.txt` in `outputDirectory`
- Whisper model is loaded once and reused across all files
- Failed files are recorded; remaining files continue processing
- Batch summary report is generated with per-file status
- Console shows batch-level progress (`[File X/Y]`)
- Ctrl+C cancels the batch gracefully without corrupting completed outputs
- All existing unit and end-to-end tests continue to pass
- New unit and end-to-end tests cover batch-specific behavior
