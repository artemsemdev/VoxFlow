# Release Process

Current state of VoxFlow release and delivery workflows.

Implementation snapshot: 2026-06-25.

## Current Scope

VoxFlow is currently distributed as source-built local artifacts. The repository has automated CI for build/test validation, but it does not yet have automated CD, signed release publishing, hosted artifacts, or package registry distribution.

The current release process consists of:

1. **Validate in CI** - `.github/workflows/ci.yml` builds/tests Core, CLI, MCP, and headless Desktop paths on pull requests and pushes to primary branches. `.github/workflows/codeql.yml` runs C# CodeQL analysis for Core, CLI, and MCP.
2. **Build locally** - `dotnet build` or `dotnet publish` from source.
3. **Package locally** - `./scripts/build-macos.sh` produces local macOS artifacts and a SHA-256 checksum.
4. **Smoke test locally** - run the test suite and per-host smoke checks (see [docs/runbooks/smoke-tests.md](../runbooks/smoke-tests.md)).

There are no published release artifacts and no package registry distribution at this time.

## Release Checklist

Before tagging a release:

- [ ] CI is green for the release branch or commit
- [ ] Clean build passes: `dotnet build VoxFlow.sln --no-incremental`
- [ ] All tests pass: `dotnet test VoxFlow.sln --no-restore`
- [ ] Per-host smoke tests pass (see [docs/runbooks/smoke-tests.md](../runbooks/smoke-tests.md))
- [ ] Desktop UI automation passes: `./scripts/run-desktop-ui-tests.sh`
- [ ] Local macOS package build succeeds and produces an artifact checksum
- [ ] Release notes or changelog entry summarize user-visible changes
- [ ] Architecture documentation is current with implementation
- [ ] `README.md` reflects the current project status
- [ ] No secrets, private recordings, or sensitive transcripts in tracked files

## Versioning

VoxFlow does not currently use a formal cross-host release versioning scheme. The MCP server has a user-visible server version string (`ServerVersion`, currently `1.0.0`, in `McpOptions`), but the app, CLI, MCP server version string, package metadata, and Git tags are not yet governed by one documented release policy.

Version management is a future release-readiness task before external distribution.

## What Is Not Yet Automated

| Concern | Current State | Notes |
|---------|--------------|-------|
| CI | Implemented | `.github/workflows/ci.yml` validates Core/CLI/MCP on Linux and headless Desktop on macOS |
| CodeQL | Partially implemented | `.github/workflows/codeql.yml` analyzes Core/CLI/MCP on Ubuntu; Desktop coverage is not included yet |
| CD / artifact publishing | Not implemented | No automated release upload, package registry, or hosted artifact channel |
| Code signing | Not implemented | Local builds are unsigned |
| Notarization | Not implemented | Required for Gatekeeper-compatible distribution |
| Distribution artifact choice | Not finalized | `build-macos.sh` produces local macOS artifacts; first external release still needs to choose the expected `.app`, `.pkg`, `.dmg`, or combination |
| Release artifact hosting | Not implemented | No distribution channel configured |
| Changelog generation | Not implemented | Decision log in `docs/architecture/06-decision-log.md` tracks architectural changes |

Each of these would be addressed when the project moves toward external distribution.
