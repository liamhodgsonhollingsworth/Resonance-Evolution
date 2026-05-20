"""
``python -m tools.list_transcripts`` — enumerate every Claude Code
session JSONL on disk with summary metadata. SPEC-070.

Shared parser library lives in ``tools.transcript_reader``.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

from tools.transcript_reader import (
    PROJECTS_DIR,
    first_user_message,
    list_all_sessions,
)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "List every Claude Code session JSONL on disk with summary "
            "metadata (SPEC-070)."
        ),
    )
    parser.add_argument(
        "--project",
        help="Substring filter on the project slug (e.g. 'Apeiron').",
    )
    parser.add_argument(
        "--with-summary",
        action="store_true",
        help="Include the first user prompt summary per session (slower).",
    )
    parser.add_argument(
        "--sort",
        choices=("mtime", "project", "id"),
        default="mtime",
        help="Sort order (default: most-recently-modified first).",
    )
    args = parser.parse_args(argv)

    sessions = list_all_sessions(project_filter=args.project)
    if not sessions:
        print(f"(no sessions under {PROJECTS_DIR})", file=sys.stderr)
        return 0

    if args.sort == "mtime":
        sessions.sort(key=lambda s: s["mtime"], reverse=True)
    elif args.sort == "project":
        sessions.sort(key=lambda s: (s["project_slug"], -s["mtime"]))
    elif args.sort == "id":
        sessions.sort(key=lambda s: s["session_id"])

    for s in sessions:
        ts = datetime.fromtimestamp(s["mtime"], tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M",
        )
        size_kb = s["size_bytes"] / 1024
        line = (
            f"{s['session_id']}  {ts}  {size_kb:>7.1f}KB  "
            f"{s['project_slug']}"
        )
        if args.with_summary:
            summary = first_user_message(Path(s["path"]))
            line += f"  | {summary}"
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
