#!/usr/bin/env python3
# Forbid literal `${{ }}` inside action input/output descriptions.
# `act` rejects expressions in description: strings (despite GitHub treating
# them as literal text). See PRs #3, #4, #9 for prior occurrences.

from __future__ import annotations

import glob
import sys

import yaml

DOLLAR_BRACE = "$" + "{" + "{"


def main() -> int:
    fail = False
    for path in sorted(glob.glob("*/action.yml")):
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        for kind in ("inputs", "outputs"):
            for name, spec in (doc.get(kind) or {}).items():
                desc = (spec or {}).get("description") or ""
                if DOLLAR_BRACE in desc:
                    print(
                        f"::error file={path}::{kind}.{name}.description contains "
                        f"literal {DOLLAR_BRACE} }}}}; act rejects expressions in "
                        f"description fields. Rephrase in plain English."
                    )
                    fail = True
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
