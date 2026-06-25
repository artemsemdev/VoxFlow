# ADR-026: Scheduled dependency audit with manual remediation

## Status

Accepted (2026-06-26).

Automation is **documented here but not yet enabled**. The proposed workflow is
included below as a reviewable artifact; saving it into `.github/workflows/` is a
separate, deliberate follow-up (see [Enabling checklist](#enabling-checklist-future-pr)).

This ADR resolves the evaluation requested in
[#84](https://github.com/artemsemdev/VoxFlow/issues/84) and complements the
manual [dependency update runbook](../runbooks/dependency-updates.md).

## Context

- The [dependency update runbook](../runbooks/dependency-updates.md) defines a
  thorough **manual** process with seven update lanes (security fix, patch/minor,
  major migration, .NET/MAUI major, MCP SDK, Whisper/native runtime, test
  tooling) and two standard audit commands.
- NuGet versions are centrally managed in `Directory.Packages.props`
  (ADR-style central package management).
- #84 asked us to evaluate automated dependency governance — a dependency bot,
  a scheduled package audit, or automated reporting — **separately** from the
  documentation-only runbook PR, so it could be scoped without mixing in version
  changes.
- VoxFlow is a local-first project maintained by a very small team. The cost we
  most want to avoid is a steady stream of bot-generated update PRs that each
  still require the runbook's host-specific validation (Desktop/native/MCP) that
  a bot cannot perform. The signal we most want to keep is **early warning of
  vulnerable packages** on the default branch.

## Decision

Adopt a **scheduled GitHub Actions package audit** that periodically runs the
two standard audit commands and reports findings as a single tracked issue.
**Do not** adopt an automated update-PR bot (Dependabot or Renovate) at this
time. Remediation stays manual and continues to follow the runbook lanes.

The audit is read-only: it changes no package versions and opens no update PRs.

### Cadence

- **Weekly** on a schedule (`cron: '0 6 * * 1'`, Mondays 06:00 UTC), plus
  on-demand via `workflow_dispatch`.
- Vulnerability findings are treated as **high priority**; merely-outdated
  findings are routine and batched into the next maintenance window.

### Reporting

- The job runs the runbook's two commands and captures their output:
  - `dotnet list VoxFlow.sln package --vulnerable --include-transitive`
  - `dotnet list VoxFlow.sln package --outdated`
- It runs on **`macos-latest`** so the whole solution — including the MAUI
  Desktop / Mac Catalyst project — restores. (On Linux the Desktop target
  framework does not restore, so a solution-wide audit there would miss
  Desktop-only packages. `ci.yml` deliberately restores only Core/CLI/MCP on
  Ubuntu; the audit needs broader coverage, so it pays for a macOS runner at the
  low weekly cadence.)
- Results are posted to a **single rolling tracking issue** (created on first
  run, updated thereafter) so findings are visible without spamming new issues.
- When the vulnerability audit is non-empty, the job **fails (red)** so the
  signal is impossible to miss in the Actions tab.

### Grouping rules

The audit does not open PRs, so "grouping" governs how the **remediation** PRs a
finding triggers should be shaped. They follow the existing runbook lanes:

| Finding | Lane | PR shape |
|---|---|---|
| Vulnerable package | Security fix | Immediate, isolated; only the affected family + directly required companions |
| Outdated within same major | Patch/minor maintenance | Batched, but only closely related packages together |
| New major available | Major migration | Separate migration issue + PR with compatibility notes |
| .NET SDK / MAUI / Mac Catalyst major | .NET or MAUI major | Dedicated compatibility spike first |
| `ModelContextProtocol` change | MCP SDK | Focused MCP PR; not mixed with transcription changes |
| `Whisper.net` / native runtime change | Whisper/native runtime | Focused runtime PR; native/macOS risk called out |
| xUnit / test SDK / coverlet / skip infra | Test tooling | Focused test-infrastructure PR; confirm skip-count gates |

### Labels

The audit issue is labelled so it routes through the existing triage scheme:

- `dependencies` — **new label to create** (e.g. colour `#0366d6`), applied to
  every audit issue.
- `security` + `priority-high` — **`security` is a new label to create**
  (e.g. `#b60205`), applied when the vulnerability audit is non-empty.
- `technical-debt` — applied when the issue is outdated-only (no vulnerabilities).

These labels do not exist yet; creating them is part of the enabling checklist
so this decision does not silently depend on labels that are absent.

### Proposed workflow (not yet enabled)

To enable later, save the following as `.github/workflows/dependency-audit.yml`.
It is intentionally **not** committed under `.github/workflows/` by this ADR, so
GitHub will not run it until enabling is a deliberate act.

```yaml
name: Dependency Audit

on:
  schedule:
    - cron: '0 6 * * 1' # Mondays 06:00 UTC
  workflow_dispatch: {}

permissions:
  contents: read
  issues: write

jobs:
  audit:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '9.0.x'

      - name: Restore solution
        run: dotnet restore VoxFlow.sln

      - name: Audit vulnerable packages
        id: vulnerable
        run: |
          set -o pipefail
          report=$(dotnet list VoxFlow.sln package --vulnerable --include-transitive)
          echo "$report"
          printf '%s\n' "$report" > vulnerable.txt
          # `dotnet list --vulnerable` prints a table with ">" row markers when
          # it finds anything; otherwise "has no vulnerable packages".
          if printf '%s' "$report" | grep -q 'has the following vulnerable'; then
            echo "found=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Audit outdated packages
        run: dotnet list VoxFlow.sln package --outdated | tee outdated.txt

      - name: Publish audit to tracking issue
        if: always()
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const read = f => { try { return fs.readFileSync(f, 'utf8'); } catch { return '(no output)'; } };
            const vulnerable = read('vulnerable.txt');
            const outdated = read('outdated.txt');
            const hasVuln = '${{ steps.vulnerable.outputs.found }}' === 'true';
            const title = 'Dependency audit';
            const body = [
              `_Updated by the scheduled dependency audit (run ${context.runId})._`,
              '',
              `## Vulnerable (${hasVuln ? 'ACTION REQUIRED' : 'clean'})`,
              '```', vulnerable, '```',
              '## Outdated',
              '```', outdated, '```',
              '',
              'Remediate via the lanes in docs/runbooks/dependency-updates.md.',
            ].join('\n');
            const labels = hasVuln ? ['dependencies', 'security', 'priority-high'] : ['dependencies', 'technical-debt'];
            const existing = await github.rest.issues.listForRepo({
              owner: context.repo.owner, repo: context.repo.repo,
              state: 'open', labels: 'dependencies', per_page: 1,
            });
            if (existing.data.length) {
              await github.rest.issues.update({
                owner: context.repo.owner, repo: context.repo.repo,
                issue_number: existing.data[0].number, body, labels,
              });
            } else {
              await github.rest.issues.create({
                owner: context.repo.owner, repo: context.repo.repo,
                title, body, labels,
              });
            }

      - name: Fail when vulnerabilities are present
        if: steps.vulnerable.outputs.found == 'true'
        run: |
          echo "::error::Vulnerable packages detected. See the dependency audit issue."
          exit 1
```

## Alternatives considered

- **Dependabot (GitHub-native update bot).** Supports NuGet with central
  package management and `groups:` that could approximate the runbook lanes, and
  brings built-in security updates. Rejected **for now** because it generates an
  ongoing stream of update PRs that a very small team must still validate
  per-lane (Desktop/native/MCP host-specific checks a bot cannot run); the
  triage cost outweighs the benefit at the current team size. Revisit when team
  capacity grows or PR volume becomes manageable with grouping.
- **Renovate.** The most capable option for grouping/scheduling and has the best
  central-package-management support. Rejected **for now** for the same
  triage-volume reason, plus it requires installing a third-party GitHub App and
  maintaining a larger configuration surface — more than this project wants to
  own today.
- **Defer automation entirely.** Rejected: the one thing the manual runbook
  cannot guarantee on its own is *timely* notice of a newly disclosed
  vulnerability between manual audits. A cheap, read-only scheduled audit closes
  exactly that gap without imposing PR-triage overhead.

## Trade-offs accepted

- **No automated update PRs.** Updates depend on a human acting on the audit
  issue. Mitigated by making the signal loud: a red job plus a labelled,
  rolling tracking issue.
- **macOS runner cost.** A solution-wide restore needs `macos-latest` to cover
  the MAUI Desktop project. Acceptable at weekly cadence; a cheaper Linux job
  would silently miss Desktop-only packages.
- **New labels required.** `dependencies` and `security` must be created before
  enabling; this is called out rather than assumed.
- **Detection heuristic.** Parsing `dotnet list --vulnerable` text output is a
  pragmatic signal, not a structured API; if the CLI output format changes the
  grep must be revisited.

## Enabling checklist (future PR)

1. Create the `dependencies` and `security` labels.
2. Save the workflow above to `.github/workflows/dependency-audit.yml`.
3. Trigger one manual `workflow_dispatch` run and confirm the tracking issue is
   created with the expected labels and content.
4. Confirm a clean run leaves the job green and a vulnerable run turns it red.
