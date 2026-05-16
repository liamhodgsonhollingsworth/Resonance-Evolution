"""
Parser for tasks.md — a plain markdown checklist.

Recognized line shapes:
    - [ ] open task
    - [x] done task
    - [~] in-progress task
    - [-] cancelled task
    - * [ ] alternative bullet form

Lines without checkbox shape are ignored (free-form notes / headers).
Indented sub-bullets attach to the previous task as continuation in
`body`.
"""

import re
from typing import List, Dict, Any


_LINE_RE = re.compile(r"^\s*[-*]\s*\[(?P<box>[ x~\-])\]\s*(?P<title>.+?)\s*$")
_STATUS = {" ": "pending", "x": "done", "~": "in_progress", "-": "cancelled"}


def parse(text: str) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    current: Dict[str, Any] | None = None

    for line_no, raw in enumerate(text.splitlines(), start=1):
        match = _LINE_RE.match(raw)
        if match:
            current = {
                "id": f"task:{line_no}",
                "title": match.group("title"),
                "body": "",
                "status": _STATUS[match.group("box")],
                "meta": {"line": line_no},
            }
            items.append(current)
            continue

        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            current = None  # blank line or header breaks continuation
            continue

        if current is not None and (raw.startswith("  ") or raw.startswith("\t")):
            sep = "\n" if current["body"] else ""
            current["body"] += sep + stripped

    return items
