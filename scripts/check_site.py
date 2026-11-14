"""Post-render guard: fail the build if data files land in _site/ unapproved.

Runs automatically after every `quarto render` (see post-render in _quarto.yml)
and can be run by hand: `python scripts/check_site.py`.

Rules
- Any data-like file in the output must match a pattern in
  scripts/published-data.txt (aggregated tables you meant to publish).
- Files under a blocked path segment (raw, transcripts, ...) always fail,
  even if allowlisted.
"""

from __future__ import annotations

import os
import sys
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / os.environ.get("QUARTO_PROJECT_OUTPUT_DIR", "_site")
ALLOWLIST = Path(__file__).resolve().parent / "published-data.txt"

DATA_EXTENSIONS = {
    ".csv", ".tsv", ".txt", ".json", ".geojson", ".parquet", ".feather",
    ".arrow", ".rds", ".rda", ".rdata", ".pkl", ".pickle", ".xlsx", ".xls",
    ".sqlite", ".db", ".duckdb", ".gpkg", ".shp", ".pmtiles", ".zip", ".gz",
}
BLOCKED_SEGMENTS = {"raw", "data-raw", "raw-data", "transcripts", "scrape", "scraping"}

# Files Quarto itself writes
QUARTO_GENERATED = {"search.json", "listings.json", "robots.txt"}
QUARTO_DIRS = {"site_libs"}


def load_allowlist() -> list[str]:
    if not ALLOWLIST.exists():
        return []
    lines = ALLOWLIST.read_text(encoding="utf-8").splitlines()
    return [ln.strip() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


def check(site: Path) -> list[str]:
    allowed = load_allowlist()
    problems: list[str] = []

    for path in sorted(p for p in site.rglob("*") if p.is_file()):
        rel = path.relative_to(site).as_posix()
        parts = rel.split("/")

        if parts[0] in QUARTO_DIRS or rel in QUARTO_GENERATED:
            continue

        blocked = BLOCKED_SEGMENTS.intersection(s.lower() for s in parts[:-1])
        if blocked:
            problems.append(f"{rel}  (blocked folder: {', '.join(sorted(blocked))})")
            continue

        if path.suffix.lower() in DATA_EXTENSIONS and not any(fnmatch(rel, pat) for pat in allowed):
            problems.append(f"{rel}  (data file not in scripts/published-data.txt)")

    return problems


def main() -> int:
    if not SITE.exists():
        print(f"check_site: {SITE} not found; nothing to check.")
        return 0

    problems = check(SITE)
    if problems:
        print("\ncheck_site: unapproved data files in the rendered site:\n", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "\nRemove them from the page's resources, or add an aggregated file's path "
            "to scripts/published-data.txt.\n",
            file=sys.stderr,
        )
        return 1

    print("check_site: no unapproved data files in _site/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
