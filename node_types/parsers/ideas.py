"""
Parser for Alethea's ideas_queue.md (and structurally similar idea logs).

Entries follow the documented format in ideas_queue.md:

    ### <date> — <short title>

    **Source:** ...
    **Proposed direction:** ...
    **Summary:** ...

A horizontal-rule, the next `###`, or a `## Resolved` header ends an
entry. The Resolved section's entries are returned with
`status = "resolved"`, the Queue section's entries with
`status = "pending"`.

Empty placeholder entries (the literal `(Empty. ...)` paragraph) are
ignored.
"""

import re
from typing import List, Dict, Any

from node_types.parsers import attach_default_actions


_ENTRY_RE = re.compile(r"^###\s*(?P<title>.+?)\s*$")
_SECTION_RE = re.compile(r"^##\s+(?P<section>.+?)\s*$")
_FIELD_RE = re.compile(r"^\*\*(?P<key>[^:*]+):\*\*\s*(?P<value>.+?)\s*$")


def parse(text: str) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    current: Dict[str, Any] | None = None
    section = "Queue"

    for line_no, raw in enumerate(text.splitlines(), start=1):
        section_match = _SECTION_RE.match(raw)
        if section_match:
            section = section_match.group("section").split()[0]  # "Queue", "Resolved"
            _flush(items, current)
            current = None
            continue

        entry_match = _ENTRY_RE.match(raw)
        if entry_match:
            _flush(items, current)
            status = "resolved" if section.lower().startswith("resolved") else "pending"
            current = {
                "id": f"idea:{line_no}",
                "title": entry_match.group("title"),
                "body": "",
                "status": status,
                "meta": {"line": line_no, "section": section},
            }
            continue

        if current is None:
            continue

        field_match = _FIELD_RE.match(raw)
        if field_match:
            key = field_match.group("key").strip().lower().replace(" ", "_")
            current["meta"][key] = field_match.group("value")
            sep = "\n" if current["body"] else ""
            current["body"] += sep + f"{field_match.group('key')}: {field_match.group('value')}"
        elif raw.strip():
            sep = "\n" if current["body"] else ""
            current["body"] += sep + raw.strip()

    _flush(items, current)
    return attach_default_actions(items)


def _flush(items: List[Dict[str, Any]], entry: Dict[str, Any] | None) -> None:
    if entry is not None:
        items.append(entry)
