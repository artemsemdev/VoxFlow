"""Fail validation on complete build logs or structured xcresult warnings."""

import argparse
import json
import re
import sys


def xcresult_warnings(report):
    """Read both aggregate and action-local legacy xcresult issues, without duplicate reports."""
    if not isinstance(report, dict) or not isinstance(report.get("issues"), dict):
        raise ValueError("expected an xcresult report with an issues object")
    found = set()

    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in ("warningSummaries", "testWarningSummaries"):
                    if not isinstance(child, dict) or not isinstance(child.get("_values", []), list):
                        raise ValueError("invalid xcresult warning collection")
                    for issue in child.get("_values", []):
                        if not isinstance(issue, dict) or not isinstance(issue.get("message"), dict):
                            raise ValueError("invalid xcresult warning")
                        message = issue["message"].get("_value")
                        if not isinstance(message, str):
                            raise ValueError("invalid xcresult warning message")
                        location = issue.get("documentLocationInCreatingWorkspace", {}).get("url", {}).get("_value", "")
                        found.add((message, location))
                else:
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(report)
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--xcresult-json", action="append", default=[],
                        help="legacy xcresulttool JSON export; repeat for multiple bundles")
    args = parser.parse_args()
    found = False
    for path in args.logs:
        try:
            with open(path, encoding="utf-8", errors="replace") as log:
                for number, line in enumerate(log, 1):
                    if re.search(r"\bwarning:", line, re.IGNORECASE):
                        print(f"{path}:{number}: {line.rstrip()}", file=sys.stderr)
                        found = True
        except OSError as error:
            parser.error(str(error))
    for path in args.xcresult_json:
        try:
            with open(path, encoding="utf-8") as report:
                warnings = xcresult_warnings(json.load(report))
            for message, location in warnings:
                print(f"{path}: {location + ': ' if location else ''}{message}", file=sys.stderr)
                found = True
        except (OSError, ValueError, TypeError, AttributeError) as error:
            parser.error(f"{path}: {error}")
    if found:
        print("Validation failed: warnings were emitted.", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
