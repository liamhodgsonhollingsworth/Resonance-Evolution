"""
``python -m tools.read_transcript <session_id>`` — render a past
Claude Code session JSONL as readable Markdown. SPEC-070.

Shared parser library lives in ``tools.transcript_reader``.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from tools.transcript_reader import (
    find_session_jsonl,
    parse_transcript,
    render_markdown,
)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Render a past Claude Code session transcript as readable "
            "Markdown (SPEC-070)."
        ),
    )
    parser.add_argument(
        "session_id",
        help="The session UUID (filename stem of the JSONL).",
    )
    parser.add_argument(
        "--project",
        help="Project slug to scope the search (otherwise all projects).",
    )
    parser.add_argument(
        "--out",
        help="Write Markdown to this file instead of stdout.",
    )
    parser.add_argument(
        "--include-thinking",
        action="store_true",
        help="Include extended-thinking blocks (default: omitted).",
    )
    args = parser.parse_args(argv)

    path = find_session_jsonl(args.session_id, args.project)
    if path is None:
        print(f"session not found: {args.session_id}", file=sys.stderr)
        return 1

    transcript = parse_transcript(path)
    rendered = render_markdown(
        transcript, include_thinking=args.include_thinking,
    )

    if args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
