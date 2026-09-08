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
        ["swift", "package", "--package-path", package_path, "describe", "--type", "json"],
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


# Only `target_dependencies` (in-package targets) are walked. `product_dependencies`
# (products of other packages) are ignored on purpose: VoxFlowKit is a single package
# with no local sibling packages, and Package.resolved changes already select ALL.
# Revisit if a second local package appears under v2/.
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
    parser.add_argument("--files-json", help="JSON array of changed files (repository-relative), appended to FILES")
    args = parser.parse_args(argv)

    files = list(args.files)
    if args.files_json:
        with open(args.files_json, encoding="utf-8") as handle:
            files.extend(json.load(handle))

    relative: list[str] = []
    for path in files:
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
