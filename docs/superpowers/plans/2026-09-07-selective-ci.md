# VoxFlow v2 Selective CI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ci-v2.yml` runs only what a change can affect: docs-only PRs run nothing on macOS, package-only PRs run the changed modules' tests plus their dependents, app/workflow changes (and every push to `develop`/`master`, or the `ci:full` label) run the full `VoxFlow` scheme. One required check, `CI v2 / result`, stays green or red regardless of which jobs ran.

**Architecture:** A cheap Ubuntu job classifies the PR's changed files into buckets with `dorny/paths-filter`. A Python script derives the affected test targets from `swift package describe --type json` (no hand-maintained dependency map). Ladder jobs are gated by the buckets; an aggregating `result` job is the single status check.

**Tech Stack:** GitHub Actions (`dorny/paths-filter@v4`, `macos-15`, `ubuntu-latest`), Python 3 (stdlib only, `unittest`), SwiftPM (`swift package describe`, `swift test --filter`).

**Spec:** Issue #116 (design approved by the owner on 2026-09-07); v2 design spec section 7 (`v2/docs/superpowers/specs/2026-09-07-voxflow-v2-design.md`).

## Global Constraints

- Only these paths change: `v2/scripts/**`, `.github/workflows/ci-v2.yml`, `v2/README.md`. `codeql-v2.yml`, the v1 workflows and all Swift code stay untouched.
- Python: stdlib only, runs on the GitHub `ubuntu-latest` and `macos-15` images' default `python3`; no third-party packages, no `pip`.
- Test-target selection is derived from `swift package describe --type json` at run time; the script never hardcodes module names.
- Safe defaults: anything the script cannot map (manifest changes, unknown paths) selects everything (`ALL`).
- Commits: Conventional Commits, authored by the repository owner only; no `Co-authored-by`, no AI attribution anywhere.
- Branch `feature/116-selective-ci` (from `develop`); PR into `develop`.
- Verified facts to rely on: `swift test --filter '^(VoxFlowFilesTests|VoxFlowMCPTests)\.'` runs exactly those two targets' tests; `swift package describe --type json` emits `targets[]` with `name`, `type` (`library`/`test`/`executable`), `path` (e.g. `Sources/VoxFlowFiles`), `target_dependencies` (names).

---

### Task 1: `affected_tests.py` with unit tests

**Files:**
- Create: `v2/scripts/affected_tests.py`
- Create: `v2/scripts/tests/test_affected_tests.py`
- Create: `v2/scripts/tests/fixtures/demo-describe.json`

**Interfaces:**
- Consumes: nothing.
- Produces: CLI `python3 v2/scripts/affected_tests.py --package-path v2/VoxFlowKit [--describe-json FILE] [--format names|regex] FILE...` printing either `ALL`, an empty line (nothing affected), or the affected test targets (names: space-separated; regex: `^(A|B)\.`). Python API: `affected_test_targets(describe: dict, changed: list[str]) -> set[str] | Literal["ALL"]`.

- [ ] **Step 1: Write the fixture describe JSON**

`v2/scripts/tests/fixtures/demo-describe.json` (shape of `swift package describe --type json`, reduced to the fields the script reads):

```json
{
  "name": "Demo",
  "targets": [
    {"name": "Core", "type": "library", "path": "Sources/Core", "target_dependencies": []},
    {"name": "A", "type": "library", "path": "Sources/A", "target_dependencies": ["Core"]},
    {"name": "B", "type": "library", "path": "Sources/B", "target_dependencies": ["A"]},
    {"name": "Tool", "type": "executable", "path": "Sources/Tool", "target_dependencies": ["B"]},
    {"name": "CoreTests", "type": "test", "path": "Tests/CoreTests", "target_dependencies": ["Core"]},
    {"name": "ATests", "type": "test", "path": "Tests/ATests", "target_dependencies": ["A"]},
    {"name": "BTests", "type": "test", "path": "Tests/BTests", "target_dependencies": ["B"]}
  ]
}
```

- [ ] **Step 2: Write the failing tests**

`v2/scripts/tests/test_affected_tests.py`:

```python
import json
import pathlib
import subprocess
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))

import affected_tests  # noqa: E402

FIXTURE = HERE / "fixtures" / "demo-describe.json"


def describe():
    return json.loads(FIXTURE.read_text())


class AffectedTestTargets(unittest.TestCase):
    def test_leaf_module_change_selects_only_its_tests(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/B/Foo.swift"])
        self.assertEqual(got, {"BTests"})

    def test_middle_module_change_selects_dependents(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/A/Bar.swift"])
        self.assertEqual(got, {"ATests", "BTests"})

    def test_root_module_change_selects_everything_downstream(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/Core/Version.swift"])
        self.assertEqual(got, {"CoreTests", "ATests", "BTests"})

    def test_test_target_change_selects_itself(self):
        got = affected_tests.affected_test_targets(describe(), ["Tests/ATests/ATests.swift"])
        self.assertEqual(got, {"ATests"})

    def test_executable_change_selects_nothing(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/Tool/main.swift"])
        self.assertEqual(got, set())

    def test_manifest_change_selects_all(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Package.swift"]), "ALL")
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Package.resolved"]), "ALL")

    def test_unknown_path_selects_all(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Plugins/X/y.swift"]), "ALL")

    def test_no_changes_selects_nothing(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), []), set())

    def test_mixed_changes_union(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/B/Foo.swift", "Tests/CoreTests/T.swift"])
        self.assertEqual(got, {"BTests", "CoreTests"})


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        cmd = [sys.executable, str(SCRIPTS / "affected_tests.py"), "--package-path", "v2/VoxFlowKit",
               "--describe-json", str(FIXTURE), *args]
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()

    def test_strips_package_prefix_and_prints_names(self):
        self.assertEqual(self.run_cli("v2/VoxFlowKit/Sources/B/Foo.swift"), "BTests")

    def test_regex_format(self):
        self.assertEqual(self.run_cli("--format", "regex", "v2/VoxFlowKit/Sources/A/Bar.swift"),
                         r"^(ATests|BTests)\.")

    def test_all_is_printed_verbatim(self):
        self.assertEqual(self.run_cli("v2/VoxFlowKit/Package.swift"), "ALL")

    def test_file_outside_package_selects_all(self):
        self.assertEqual(self.run_cli("v2/VoxFlow/App/VoxFlowApp.swift"), "ALL")

    def test_empty_input_prints_empty_line(self):
        self.assertEqual(self.run_cli(), "")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s v2/scripts/tests -v 2>&1 | tail -5`
Expected: `ModuleNotFoundError: No module named 'affected_tests'` (RED).

- [ ] **Step 4: Write the script**

`v2/scripts/affected_tests.py`:

```python
#!/usr/bin/env python3
"""Select the SwiftPM test targets affected by a set of changed files.

Reads the package graph from `swift package describe --type json` (or a saved copy via
--describe-json) and prints the test targets whose code, or whose dependencies' code,
changed. Prints "ALL" when the change cannot be mapped safely (manifest edits, unknown
paths, files outside the package) and an empty line when nothing is affected.

Used by .github/workflows/ci-v2.yml to run `swift test --filter` on package-only PRs.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import PurePosixPath

ALL = "ALL"
MANIFEST_FILES = {"Package.swift", "Package.resolved"}


def load_describe(package_path: str, describe_json: str | None) -> dict:
    if describe_json:
        with open(describe_json, encoding="utf-8") as handle:
            return json.load(handle)
    output = subprocess.run(
        ["swift", "package", "describe", "--type", "json", "--package-path", package_path],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(output)


def _target_for(path: str, targets: list[dict]) -> dict | None:
    """Longest target `path` that is a prefix of the changed file's path."""
    parts = PurePosixPath(path).parts
    best = None
    for target in targets:
        tparts = PurePosixPath(target["path"]).parts
        if parts[: len(tparts)] == tparts and (best is None or len(tparts) > len(PurePosixPath(best["path"]).parts)):
            best = target
    return best


def _dependents(targets: list[dict]) -> dict[str, set[str]]:
    """name -> names of targets that depend on it directly."""
    graph: dict[str, set[str]] = {t["name"]: set() for t in targets}
    for target in targets:
        for dep in target.get("target_dependencies", []):
            graph.setdefault(dep, set()).add(target["name"])
    return graph


def affected_test_targets(describe: dict, changed: list[str]) -> set[str] | str:
    """Return the affected test target names, or ALL when selection is not safe."""
    targets = describe["targets"]
    by_name = {t["name"]: t for t in targets}
    dependents = _dependents(targets)
    affected: set[str] = set()
    for path in changed:
        if PurePosixPath(path).name in MANIFEST_FILES and len(PurePosixPath(path).parts) == 1:
            return ALL
        target = _target_for(path, targets)
        if target is None:
            return ALL
        # Walk downstream: everything that (transitively) depends on the changed target.
        stack = [target["name"]]
        seen: set[str] = set()
        while stack:
            name = stack.pop()
            if name in seen:
                continue
            seen.add(name)
            stack.extend(dependents.get(name, ()))
        affected.update(n for n in seen if by_name[n]["type"] == "test")
    return affected


def _strip_package_prefix(path: str, package_path: str) -> str | None:
    prefix = PurePosixPath(package_path).parts
    parts = PurePosixPath(path).parts
    if parts[: len(prefix)] != prefix:
        return None
    return str(PurePosixPath(*parts[len(prefix):])) if len(parts) > len(prefix) else ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--package-path", required=True, help="package directory, e.g. v2/VoxFlowKit")
    parser.add_argument("--describe-json", help="saved output of `swift package describe --type json`")
    parser.add_argument("--format", choices=("names", "regex"), default="names")
    parser.add_argument("files", nargs="*", help="changed files, paths relative to the repository root")
    args = parser.parse_args(argv)

    relative: list[str] = []
    for path in args.files:
        stripped = _strip_package_prefix(path, args.package_path)
        if stripped is None:
            print(ALL)
            return 0
        relative.append(stripped)

    describe = load_describe(args.package_path, args.describe_json)
    result = affected_test_targets(describe, relative)
    if result == ALL:
        print(ALL)
    elif not result:
        print("")
    elif args.format == "regex":
        print("^(" + "|".join(sorted(result)) + r")\.")
    else:
        print(" ".join(sorted(result)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s v2/scripts/tests -v 2>&1 | tail -3`
Expected: `Ran 14 tests` … `OK`.

- [ ] **Step 6: Smoke-test against the real package**

Run:
```bash
python3 v2/scripts/affected_tests.py --package-path v2/VoxFlowKit --format regex v2/VoxFlowKit/Sources/VoxFlowFiles/FilesModule.swift
python3 v2/scripts/affected_tests.py --package-path v2/VoxFlowKit v2/VoxFlowKit/Sources/VoxFlowCore/Version.swift | tr ' ' '\n' | wc -l
```
Expected: first prints `^(VoxFlowFilesTests)\.`; second prints `9`.

- [ ] **Step 7: Commit**

```bash
chmod +x v2/scripts/affected_tests.py
git add v2/scripts
git commit -m "ci(v2): add affected_tests.py to derive test targets from the package graph

Reads swift package describe JSON, walks transitive dependents of the
changed targets and prints the test targets to run (or ALL when a change
cannot be mapped safely). Covered by stdlib unittest with a fixture graph.
Refs #116."
```

---

### Task 2: Ladder workflow and README

**Files:**
- Modify: `.github/workflows/ci-v2.yml` (replace whole file)
- Modify: `v2/README.md` (CI section)

**Interfaces:**
- Consumes: `python3 v2/scripts/affected_tests.py --package-path v2/VoxFlowKit --format regex <files>` from Task 1 (prints `ALL`, empty, or a regex).
- Produces: status check `CI v2 / result`.

- [ ] **Step 1: Replace `ci-v2.yml`**

```yaml
name: CI v2

# Validate the v2 native Swift rewrite under v2/ (see issues #105, #116).
#
# Ladder (pull requests): a cheap Ubuntu job buckets the changed files, then
#   docs only              → nothing else runs, `result` is green
#   v2/scripts/** only     → Python unit tests for the CI scripts
#   VoxFlowKit only        → swift test for the changed modules and their dependents
#   app / project.yml / this workflow / label `ci:full` → full VoxFlow scheme (build + all tests)
# Pushes to develop/master and manual runs always run the full scheme.
# Branch protection requires only the `result` job.
on:
  push:
    branches:
      - master
      - develop
    paths:
      - 'v2/**'
      - '.github/workflows/ci-v2.yml'
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-v2-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: read

env:
  PACKAGE_PATH: v2/VoxFlowKit

jobs:
  changes:
    name: Classify changes
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      docs: ${{ steps.filter.outputs.docs }}
      scripts: ${{ steps.filter.outputs.scripts }}
      package: ${{ steps.filter.outputs.package }}
      package_files: ${{ steps.filter.outputs.package_files }}
      app: ${{ steps.filter.outputs.app }}
      workflow: ${{ steps.filter.outputs.workflow }}
      full: ${{ steps.mode.outputs.full }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Bucket changed files
        id: filter
        uses: dorny/paths-filter@v4
        with:
          list-files: shell
          filters: |
            docs:
              - 'v2/docs/**'
              - 'v2/design/**'
              - 'v2/**/*.md'
            scripts:
              - 'v2/scripts/**'
            package:
              - 'v2/VoxFlowKit/**'
            app:
              - 'v2/VoxFlow/**'
              - 'v2/VoxFlowTests/**'
              - 'v2/project.yml'
            workflow:
              - '.github/workflows/ci-v2.yml'

      # Full run when: not a PR (push/dispatch), the app or this workflow changed,
      # or the PR carries the `ci:full` label.
      - name: Decide run mode
        id: mode
        env:
          IS_PR: ${{ github.event_name == 'pull_request' }}
          HAS_LABEL: ${{ contains(github.event.pull_request.labels.*.name, 'ci:full') }}
          APP: ${{ steps.filter.outputs.app }}
          WORKFLOW: ${{ steps.filter.outputs.workflow }}
        run: |
          if [ "$IS_PR" != "true" ] || [ "$HAS_LABEL" = "true" ] || [ "$APP" = "true" ] || [ "$WORKFLOW" = "true" ]; then
            echo "full=true" >> "$GITHUB_OUTPUT"; echo "::notice::Run mode: full"
          else
            echo "full=false" >> "$GITHUB_OUTPUT"; echo "::notice::Run mode: selective"
          fi

  script-tests:
    name: CI script tests
    needs: changes
    if: needs.changes.outputs.scripts == 'true' || needs.changes.outputs.full == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Run unit tests
        run: python3 -m unittest discover -s v2/scripts/tests -v

  package-tests:
    name: Package tests (affected modules)
    needs: changes
    if: needs.changes.outputs.full != 'true' && needs.changes.outputs.package == 'true'
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode 26
        run: |
          set -euo pipefail
          XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
          [ -n "$XCODE" ] || { echo "::error::No Xcode 26.x on this runner image"; exit 1; }
          sudo xcode-select -s "$XCODE"
          swift --version

      - name: Cache SPM build
        uses: actions/cache@v4
        with:
          path: v2/VoxFlowKit/.build
          key: ${{ runner.os }}-spm-build-${{ hashFiles('v2/VoxFlowKit/Package.swift', 'v2/**/Package.resolved') }}-${{ github.run_id }}
          restore-keys: |
            ${{ runner.os }}-spm-build-${{ hashFiles('v2/VoxFlowKit/Package.swift', 'v2/**/Package.resolved') }}-
            ${{ runner.os }}-spm-build-

      - name: Select affected test targets
        id: select
        env:
          CHANGED: ${{ needs.changes.outputs.package_files }}
        run: |
          set -euo pipefail
          # shellcheck disable=SC2086  # CHANGED is a shell-escaped list from paths-filter
          FILTER=$(python3 v2/scripts/affected_tests.py --package-path "$PACKAGE_PATH" --format regex $CHANGED)
          echo "filter=$FILTER" >> "$GITHUB_OUTPUT"
          echo "::notice::Test filter: ${FILTER:-<none>}"

      - name: Build package
        run: swift build --package-path "$PACKAGE_PATH"

      - name: Test affected modules
        env:
          FILTER: ${{ steps.select.outputs.filter }}
        run: |
          set -euo pipefail
          if [ -z "$FILTER" ]; then
            echo "No test target is affected by the changed files."
          elif [ "$FILTER" = "ALL" ]; then
            swift test --package-path "$PACKAGE_PATH"
          else
            swift test --package-path "$PACKAGE_PATH" --filter "$FILTER"
          fi

  full:
    name: Build & test (Swift)
    needs: changes
    if: needs.changes.outputs.full == 'true'
    runs-on: macos-15
    timeout-minutes: 30

    defaults:
      run:
        working-directory: v2

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # The image defaults to Xcode 16.x; v2 is developed with Xcode 26.x. Pick the newest 26.
      - name: Select Xcode 26
        run: |
          set -euo pipefail
          XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
          [ -n "$XCODE" ] || { echo "::error::No Xcode 26.x on this runner image"; exit 1; }
          sudo xcode-select -s "$XCODE"
          xcodebuild -version
          swift --version

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Cache SPM packages and DerivedData
        uses: actions/cache@v4
        with:
          path: |
            ~/Library/Developer/Xcode/DerivedData
            v2/VoxFlowKit/.build
          key: ${{ runner.os }}-spm-${{ hashFiles('v2/VoxFlowKit/Package.swift', 'v2/**/Package.resolved') }}-${{ github.run_id }}
          restore-keys: |
            ${{ runner.os }}-spm-${{ hashFiles('v2/VoxFlowKit/Package.swift', 'v2/**/Package.resolved') }}-
            ${{ runner.os }}-spm-

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Build
        run: |
          set -o pipefail
          xcodebuild -scheme VoxFlow -destination 'platform=macOS' build | tee build.log

      - name: Test
        run: |
          set -o pipefail
          xcodebuild -scheme VoxFlow -destination 'platform=macOS' test -resultBundlePath TestResults.xcresult | tee test.log

      - name: Package tests without Xcode project
        run: swift test
        working-directory: v2/VoxFlowKit

      - name: Upload logs and results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: v2-test-results
          path: |
            v2/build.log
            v2/test.log
            v2/TestResults.xcresult
          if-no-files-found: ignore

  # The single status check for branch protection: red if any job that ran failed
  # or was cancelled; green when jobs were skipped by the ladder.
  result:
    name: result
    needs: [changes, script-tests, package-tests, full]
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - name: Evaluate
        env:
          RESULTS: ${{ toJSON(needs) }}
        run: |
          echo "$RESULTS" | python3 -c '
          import json, sys
          needs = json.load(sys.stdin)
          bad = {k: v["result"] for k, v in needs.items() if v["result"] in ("failure", "cancelled")}
          for k, v in needs.items():
              print(f"{k}: {v[\"result\"]}")
          sys.exit(1 if bad else 0)
          '
```

- [ ] **Step 2: Validate the YAML and shell**

Run: `ruby -ryaml -e "YAML.load_file('.github/workflows/ci-v2.yml'); puts 'yaml ok'"`
Expected: `yaml ok`.
Then simulate the `result` step locally:
```bash
echo '{"changes":{"result":"success"},"script-tests":{"result":"skipped"},"package-tests":{"result":"success"},"full":{"result":"skipped"}}' | python3 -c '
import json, sys
needs = json.load(sys.stdin)
bad = {k: v["result"] for k, v in needs.items() if v["result"] in ("failure", "cancelled")}
sys.exit(1 if bad else 0)'; echo "exit=$? (want 0)"
echo '{"full":{"result":"failure"}}' | python3 -c '
import json, sys
needs = json.load(sys.stdin)
bad = {k: v["result"] for k, v in needs.items() if v["result"] in ("failure", "cancelled")}
sys.exit(1 if bad else 0)'; echo "exit=$? (want 1)"
```

- [ ] **Step 3: Update the README CI section**

Replace the `## CI` section of `v2/README.md` with:

```markdown
## CI

`.github/workflows/ci-v2.yml` runs a ladder so a small change does not pay for a full
macOS build:

| Changed files (PR) | What runs |
|---|---|
| only `v2/docs/**`, `v2/design/**`, `*.md` | nothing on macOS; `result` is green |
| `v2/scripts/**` | Python unit tests for the CI scripts (Ubuntu) |
| `v2/VoxFlowKit/**` | `swift test` for the changed modules and their dependents, derived from `swift package describe` by `v2/scripts/affected_tests.py` |
| `v2/VoxFlow/**`, `v2/VoxFlowTests/**`, `v2/project.yml`, the workflow itself, or PR label `ci:full` | full `VoxFlow` scheme: build + all tests |

Pushes to `develop`/`master` and manual runs always run the full scheme. Branch
protection needs only the `CI v2 / result` check. `codeql-v2.yml` runs CodeQL for Swift on
pushes to `develop`/`master`, weekly, and on demand.
```

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/ci-v2.yml v2/README.md
git commit -m "ci(v2): run only the jobs a change can affect

Ubuntu job buckets changed files with paths-filter; docs-only PRs run
nothing on macOS, package-only PRs run affected module tests via
affected_tests.py, app/workflow changes and pushes run the full scheme.
A single result job is the required status check. Refs #116."
git push -u origin feature/116-selective-ci
```

- [ ] **Step 5: Prove the ladder on real PRs**

Open the PR into `develop` (Task 3). Its own diff touches the workflow, so it runs `full`. Then, from the same branch, verify the other rungs with two throwaway commits pushed to short-lived branches and PRs against `develop`, each closed without merging after the run:
1. `ci-probe/docs`: edit one sentence in `v2/README.md` → expect only `changes` + `result`.
2. `ci-probe/package`: add a comment line to `v2/VoxFlowKit/Sources/VoxFlowFiles/FilesModule.swift` → expect `changes`, `package-tests` with filter `^(VoxFlowFilesTests)\.`, `result`; no `full`.
Record both run URLs in the main PR body, close the probe PRs, delete the probe branches.

---

### Task 3: Pull request

- [ ] Open the PR into `develop` per the repository template, mapping #116's acceptance criteria, with the run URLs from Task 2 Step 5. End with `Refs #116` (the issue is closed manually after merge, as merges into `develop` do not auto-close).
- [ ] Ask the owner to set branch protection on `develop` to require `CI v2 / result` (repository setting, not automated here).

## Self-review

- **Spec coverage:** #116 design points 1–4 → Task 2 workflow (`changes`, ladder jobs, `result`), Task 1 script; acceptance criteria: script tests (T1), docs-only PR (T2 step 5.1), single-module PR (T2 step 5.2), `ci:full` + pushes (T2 `mode` step), README (T2 step 3).
- **Placeholders:** none; probe branches are described with exact edits.
- **Type consistency:** script output contract (`ALL` / empty / `^(…)\.`) is identical in Task 1 code, tests and the Task 2 `Test affected modules` step; `--package-path v2/VoxFlowKit` matches `env.PACKAGE_PATH`.
