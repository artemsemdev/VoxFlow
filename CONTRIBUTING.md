# Contributing to VoxFlow

Thanks for contributing. This repository contains a local-first .NET 9 transcription system with CLI, Desktop, MCP, and shared Core projects. Contributions should preserve the project's privacy-first and configuration-driven design.

## Before You Start

- Read [README.md](README.md) for project scope and current status.
- Read [docs/developer/setup.md](docs/developer/setup.md) for prerequisites, build commands, and runtime setup.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) and the product docs before making broad design changes.
- For behavior, feature, or workflow changes that are not obviously small, open an issue first so scope and direction are aligned before implementation.

## Ground Rules

- Keep changes focused. One pull request should solve one problem or one tightly related slice of work.
- Prefer small, reviewable commits with clear messages.
- Keep the product local-only. Do not introduce cloud-hosted transcription dependencies or remote data flows without explicit maintainer approval.
- Preserve configuration-driven behavior where that pattern already exists.
- Do not include secrets, private recordings, or sensitive transcripts in code, tests, screenshots, or issue attachments.

## Development Workflow

1. Create a branch from the latest default branch.
2. Make the smallest reasonable change that solves the problem completely.
3. Add or update tests when behavior changes.
4. Update documentation when commands, configuration, architecture, or UX expectations change.
5. Run the relevant validation commands before opening a pull request.

## Local Validation

From the repository root:

```bash
dotnet restore VoxFlow.sln
dotnet build VoxFlow.sln --no-restore
dotnet test VoxFlow.sln --no-build
```

If you changed the macOS Desktop app or UI automation path, also run the desktop UI suite on macOS when possible:

```bash
./scripts/run-desktop-ui-tests.sh
```

If you cannot run a relevant validation step, say so clearly in the pull request and explain why.

## Code and Documentation Expectations

- Follow the existing naming, structure, and formatting conventions in the surrounding code.
- Prefer explicit, testable behavior over implicit or hidden side effects.
- Keep logging and diagnostics useful, but avoid leaking sensitive local file contents or user data.
- When changing product behavior, update the relevant docs in `README.md`, `SETUP.md`, `docs/product/`, or `docs/architecture/`.
- Add comments only where the code would otherwise be hard to understand.

### Async / concurrency rules

- **`async void` is only allowed for UI event handlers** (MAUI/Mac Catalyst handlers such as `*_Click`, `*_Tapped`, `*_Loaded`, drop handlers). Anything invoked from your own code returns `async Task`.
- **Every `async void` event handler must wrap its body in a top-level `try`/`catch`** that logs via `DesktopDiagnostics.LogException` (or the equivalent host-specific logger) and surfaces a user-visible error. An exception that escapes an `async void` propagates to the synchronization context and crashes the app — the framework has no Task to observe.
- **No `.GetAwaiter().GetResult()`, `.Result`, or `.Wait()` in `src/`.** These patterns deadlock under UI synchronization contexts and tie up thread-pool workers. If a sync API needs the result of async work, refactor to expose a sync core that both the async and sync paths call (`DesktopConfigurationService.LoadCore` is the reference example), or use the async-lazy `Lazy<Task<T>>` pattern (`PyannoteSidecarClient.ResponseSchema`).

### Package management rules

- **`Directory.Packages.props` at the repo root is the single source of truth for NuGet package versions.** Every `<PackageReference>` across `src/` and `tests/` is versionless; the version lives only in `Directory.Packages.props`.
- **To upgrade a package, edit `Directory.Packages.props` only.** Do not add `Version="..."` back to any `.csproj`. The acceptance grep is:
  ```bash
  grep -rEn 'PackageReference[^>]*Version=' src/ tests/ --include='*.csproj'   # 0 matches expected
  ```
- **To add a new package**: add a `<PackageVersion Include="X" Version="Y" />` line to `Directory.Packages.props`, then add a versionless `<PackageReference Include="X" />` to the consuming `.csproj`.
- **`global.json` pins the .NET SDK** to 9.0.x with `rollForward: latestFeature`. New contributors get reproducible restores without setting `DOTNET_ROOT` or pinning shells. To bump the SDK, edit `global.json` and verify CI's `actions/setup-dotnet` line still matches.

### Exception handling rules

- **Every `catch` block in `src/` must do one of three things:**
  1. **Rethrow** (after wrapping or logging) — preserve the inner exception via `throw new ... (..., ex)` so the original stack trace is recoverable.
  2. **Log** the failure — use the host-specific logger (`DesktopDiagnostics.LogException` in Desktop, `Console.Error.WriteLine` in Core/CLI/MCP until #46 wires `ILogger<T>` at the composition root). The log line should name the operation that failed and surface `ex.GetType().Name` + `ex.Message`.
  3. **Carry a one-line justification comment** explaining why the exception is intentionally suppressed (e.g. `// Process may have exited between HasExited check and Kill; swallow.`). Comments must justify silence, not just describe what's caught.
- **No bare `catch { }` blocks** with no body, no comment, and no rethrow. The strict acceptance grep is:
  ```bash
  grep -rEn "catch\s*\([^)]*\)\s*\{\s*\}" src/ --include="*.cs"
  grep -rEn "^\s*catch\s*\{" src/ --include="*.cs"
  ```
  Both should return no C# matches. Bare `catch` (no exception type) should narrow to a specific expected exception type whenever possible.

## Pull Request Expectations

Each pull request should include:

- a concise description of the problem and the change
- links to related issues or rationale if the change stands alone
- a short testing summary listing what you actually ran
- screenshots or recordings for user-facing Desktop UI changes when they help reviewers
- notes about configuration, migration, or breaking changes when applicable

PRs that mix refactors, feature work, and unrelated cleanup are harder to review and may be sent back for narrowing.

## Reporting Bugs and Requesting Features

- Use the GitHub issue templates for bug reports, feature requests, and documentation improvements.
- For security vulnerabilities, do not file a public issue. Follow [SECURITY.md](SECURITY.md).

## License

By submitting a contribution, you agree that your contribution will be licensed under the repository's [MIT License](LICENSE).
