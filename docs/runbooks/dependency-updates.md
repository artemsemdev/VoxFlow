# Dependency Update Runbook

Use this runbook to audit and update NuGet dependencies without mixing package
maintenance with unrelated feature, refactor, UI, or documentation work.

## Goals

- Keep vulnerable packages out of the default branch.
- Keep routine patch and minor updates reviewable.
- Treat major version changes as migrations with explicit risk and validation.
- Preserve central package management through `Directory.Packages.props`.

## Standard Audit Commands

Run these from the repository root:

```bash
dotnet list VoxFlow.sln package --vulnerable --include-transitive
dotnet list VoxFlow.sln package --outdated
```

Record both results in the pull request. If either command cannot reach
NuGet, state that clearly and rerun when network access is available.

## Update Lanes

| Lane | When to use | PR shape | Required validation |
|------|-------------|----------|---------------------|
| Security fix | A package is reported vulnerable | Immediate small PR; update only the affected package family and directly required companions | Vulnerability audit must be clean; run the affected project tests and full build |
| Patch/minor maintenance | Compatible updates within the same major version | Regular maintenance PR; batch closely related packages only | Outdated audit before/after; full build; relevant tests |
| Major migration | Any package moves to a new major version | Separate migration issue and PR with explicit compatibility notes | Full build/test suite; host-specific smoke tests for affected surfaces |
| .NET or MAUI major | SDK, target framework, MAUI workload, or Mac Catalyst package major changes | Dedicated compatibility spike before migration PR | Linux Core/CLI/MCP CI path, macOS Desktop build/tests, local Desktop smoke where practical |
| MCP SDK | `ModelContextProtocol` or related protocol packages change | Focused MCP PR; do not mix with transcription changes | MCP tests, tool schema tests, stdio startup smoke, path-policy regression tests |
| Whisper/native runtime | `Whisper.net` or runtime packages change | Focused runtime PR; call out native/macOS risk | Core tests, CLI smoke, Desktop build/tests, Intel bridge smoke if available |
| Test tooling | xUnit, test SDK, coverlet, or skip infrastructure changes | Focused test-infrastructure PR | All test projects; confirm skip-count gates still behave as expected |

## Package Management Rules

- `Directory.Packages.props` is the single source of truth for NuGet versions.
- Do not add `Version="..."` to `PackageReference` entries in `src/` or `tests/`.
- Add new packages by adding a `<PackageVersion Include="..." Version="..." />`
  entry to `Directory.Packages.props`, then adding a versionless
  `<PackageReference Include="..." />` to the consuming project.
- Do not combine dependency updates with unrelated product, UI, refactor, or
  documentation changes.
- Keep the PR description clear about why each package was updated.

Use this grep before opening a package PR:

```bash
grep -rEn 'PackageReference[^>]*Version=' src/ tests/ --include='*.csproj'
```

Expected result: no matches.

## Standard Validation Matrix

Every dependency PR should run:

```bash
dotnet restore VoxFlow.sln
dotnet build VoxFlow.sln --no-incremental
dotnet test VoxFlow.sln --no-build
dotnet list VoxFlow.sln package --vulnerable --include-transitive
dotnet list VoxFlow.sln package --outdated
```

Additional checks by affected area:

| Affected area | Extra checks |
|---------------|--------------|
| Core transcription, Whisper, schema, or shared Microsoft.Extensions packages | `dotnet test tests/VoxFlow.Core.Tests/VoxFlow.Core.Tests.csproj --no-build`; run a CLI smoke test when runtime behavior may change |
| CLI packages | `dotnet test tests/VoxFlow.Cli.Tests/VoxFlow.Cli.Tests.csproj --no-build`; run a CLI smoke test |
| MCP packages | `dotnet test tests/VoxFlow.McpServer.Tests/VoxFlow.McpServer.Tests.csproj --no-build`; start the MCP server and confirm diagnostics stay on stderr |
| Desktop or MAUI packages | `dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst --no-restore -p:MtouchLink=SdkOnly`; `dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-build` |
| Real Desktop UI flow | `./scripts/run-desktop-ui-tests.sh` when the update touches MAUI, WebView, Mac Catalyst runtime behavior, file picker, clipboard, or result actions |
| Speaker-labeling sidecar path | Run `Category=RequiresPython` tests only on a machine with Python/pyannote prerequisites and required model access |

If a relevant validation step cannot run locally, state why in the PR and rely
on CI only for the parts CI actually covers.

## PR Checklist

Use this checklist in dependency PR descriptions:

- [ ] Package versions changed only in `Directory.Packages.props`
- [ ] No unrelated feature/refactor/UI changes included
- [ ] Vulnerability audit result recorded
- [ ] Outdated audit result recorded
- [ ] Full build result recorded
- [ ] Relevant test projects recorded
- [ ] Host-specific smoke checks recorded or explicitly deferred with a reason
- [ ] Migration notes included for major updates

## Follow-Up Governance

Automation has been **evaluated and decided** in
[ADR-026](../adr/026-dependency-audit-automation.md): adopt a **scheduled,
read-only package audit** (weekly `dotnet list --vulnerable` / `--outdated`
reported to a rolling tracking issue) and **defer** automated update-PR bots
(Dependabot/Renovate) while the team is small. Remediation stays manual and
follows the lanes above.

The audit workflow is documented in ADR-026 but **not yet enabled** — see its
"Enabling checklist" (create the `dependencies` / `security` labels, then add
`.github/workflows/dependency-audit.yml`). Automated update PRs remain a separate
future decision to revisit as team capacity grows.
