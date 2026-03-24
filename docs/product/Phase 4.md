# Phase 4: Stabilization and 1.0

Derived from [ROADMAP.md](./ROADMAP.md). This phase is for reducing defects, defining supported scope, and cutting a defensible 1.0 release.

## Goal

Release 1.0 with an explicit supported scope and a QA result that matches that scope.

## What To Implement

### 1. Supported Scope Document

Write down exactly what 1.0 includes:

- supported operating system
- supported hosts:
  - desktop
  - CLI
  - MCP
- supported outputs
- supported workflows
- known limitations

### 2. QA Matrix

Run a practical QA matrix across:

- supported operating system (minimum macOS version through current)
- desktop single-file flow (file picker and drag-and-drop)
- desktop batch flow
- CLI single-file flow
- CLI batch flow
- MCP transcription flow (via Claude Desktop quickstart)
- model bootstrap (first download, reuse, corrupt model recovery)
- failure handling and cancellation
- auto-update flow
- accessibility: VoiceOver navigation of all desktop screens

### 3. Performance and Resource Profiling

Establish known resource requirements before 1.0:

- measure peak memory usage per model size (Base, Small, Medium, Large)
- measure transcription speed (real-time factor) for 1min, 10min, 60min audio per model
- measure disk usage: model files, temp files during processing, output bundles
- document minimum hardware requirements (RAM, disk space)

These numbers go into the supported-scope document and install docs.

### 4. Bug Fixing and Hardening

Use this phase to remove the highest-value defects only:

- install failures
- crashes
- incorrect outputs
- broken batch behavior
- broken MCP setup
- missing or misleading docs
- accessibility blockers (VoiceOver cannot navigate key flows)

### 5. Release Candidate Process

Cut at least one release candidate and validate it against the QA matrix.

Required:

- RC build
- RC checklist
- blocker classification
- hotfix rule

### 6. Final Docs Pass

Before 1.0, verify:

- install docs match the shipped build
- screenshots match the current UI
- MCP quickstarts still work
- known limitations are current

### 7. Settings Migration Testing

Verify that upgrading from Phase 1/2 builds to 1.0 does not break user configuration:

- appsettings.json schema changes are backwards-compatible or have a documented migration path
- preset files from Phase 2 are still valid
- output bundles from earlier versions are still readable in the workspace
- model storage location changes do not orphan downloaded models

## Out of Scope

- Enterprise features
- Launch campaign
- Case studies
- New product surfaces
- Formal beta program (if real users are available, use their feedback informally)

## Implementation Order

1. Write the supported-scope doc.
2. Run performance and resource profiling; document results.
3. Define the QA matrix including accessibility checks.
4. Run the matrix and fix blockers.
5. Run settings migration tests against Phase 1/2 builds.
6. Cut a release candidate.
7. Re-run the matrix and docs checks.
8. Ship 1.0.

## Practical Risks

- 1.0 scope will become vague unless it is written down first.
- QA will miss real failures if it does not include CLI, batch, MCP, and accessibility.
- Performance profiling on developer hardware may not reflect user machines — test with minimum spec if possible.
- Settings migration bugs are silent — users just see broken config. Test explicitly.

## Done When

- the supported 1.0 scope is explicit
- resource requirements are documented (RAM, disk, minimum macOS version)
- the QA matrix passes including accessibility checks
- settings migration from pre-1.0 builds is verified
- blockers are resolved or documented
- release candidate checks are complete
- 1.0 can be released without guessing what is supported
