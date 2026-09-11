"""Fail validation when a build tool emits a warning, including uppercase Xcode diagnostics."""

import argparse
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+")
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
    if found:
        print("Validation failed: build tools emitted warnings.", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
