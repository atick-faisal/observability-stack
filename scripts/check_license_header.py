#!/usr/bin/env python3
"""Ensure every Python file carries the project's SPDX licence header.

Run by the `license-header` pre-commit hook. Stdlib only, so pre-commit can build
its environment without resolving a single dependency.

Fixes in place and exits non-zero when it changed anything, which is what makes the
commit stop so the author can restage.

The year is a constant, matching LICENSE, not the current year: deriving it from the
clock would silently rewrite every header each January for no licensing reason.
"""

from __future__ import annotations

import sys
from pathlib import Path

SPDX_MARKER = "SPDX-License-Identifier: MIT"

HEADER = f"""# Copyright (c) 2026 Atick Faisal
# {SPDX_MARKER}
"""


def add_header(path: Path) -> bool:
    """Prepend the header unless it is already there. True if the file changed."""
    original = path.read_text(encoding="utf-8")

    if SPDX_MARKER in original:
        return False

    # A shebang only works on the first line, so the header goes after it. Anything
    # else — a module docstring, `from __future__ import annotations` — is happy to
    # have comments above it.
    if original.startswith("#!"):
        shebang, _, rest = original.partition("\n")
        body = rest.lstrip("\n")
        updated = shebang + "\n" + HEADER + "\n" + body
    else:
        updated = HEADER + "\n" + original.lstrip("\n")

    path.write_text(updated, encoding="utf-8")
    return True


def main(argv: list[str]) -> int:
    changed: list[Path] = []

    for name in argv:
        path = Path(name)
        if path.suffix != ".py":
            continue
        try:
            if add_header(path):
                changed.append(path)
        except OSError as exc:
            print(f"error: could not process {path}: {exc}", file=sys.stderr)
            return 1

    for path in changed:
        print(f"added licence header: {path}")

    return 1 if changed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
