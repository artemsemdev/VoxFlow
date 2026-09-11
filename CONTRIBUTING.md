# Contributing to VoxFlow

Thanks for contributing. VoxFlow is a native macOS transcription app (Swift 6, SwiftUI, whisper.cpp)
with a privacy-first design: nothing leaves the Mac except a model download the user starts.
Contributions must preserve that.

## Pull request scope

- Prefer PRs around 100–400 lines changed; up to 800 is acceptable only for mostly mechanical changes.
- Keep each PR focused on one coherent slice of work; do not mix architecture, UI, tests, refactoring
  and documentation in one large PR.
- Use the pull request template and map every acceptance criterion of the linked issue.

## Branching (GitFlow)

- `master`: released, tagged versions only.
- `develop`: integration branch; every feature PR targets it.
- `feature/<issue>-<slug>` from `develop`; `release/x.y.z` from `develop` merges to `master` with a
  tag and back into `develop`; `hotfix/*` from `master`.

## Commits

- Conventional Commits: `type(scope): summary` with `feat`, `fix`, `refactor`, `test`, `docs`, `ci`,
  `build`, `chore`.
- Fine-grained commits inside a PR are encouraged.
- All commits use the repository owner's configured Git identity; no other attribution trailers.

## Building and testing

```bash
brew install xcodegen
xcodegen generate
xcodebuild -xcconfig Build.xcconfig -scheme VoxFlow -destination 'platform=macOS' build test   # what CI runs
cd VoxFlowKit && swift test                                             # package only, fast
```

- Warnings are errors; strict concurrency is `complete`. Do not add `@unchecked Sendable`,
  `nonisolated(unsafe)` or `MainActor.assumeIsolated` without a comment that proves the invariant,
  and prefer `Mutex` / actors.
- Tests first (TDD): a failing test, then the smallest change that makes it pass. Unit tests use the
  fakes in `VoxFlowTestSupport`; tests that need a real model are gated with `.enabled(if:)` and print
  why they skipped. Tests must be deterministic: gate on state, never on `sleep`.
- Views hold no rules: thresholds, copy and naming live in view models or `VoxFlowKit`, with tests.
- `VoxFlowCore` imports Foundation only; modules import Core, never the app.

## Docs to keep in sync

- ADRs in `docs/adr/` (index in `docs/adr/README.md`) for architectural decisions.
- `docs/formats.md` for any change to the transcript output.
- `README.md` "What works today" and `CHANGELOG.md` for user-visible changes.
- Design changes go through the canvas in `design/`.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
