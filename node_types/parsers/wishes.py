"""
Parser for Apeiron's wishlist.md.

Wish entries follow:
    - **#NNN** [status] — **Title.** Optional continuation prose.

Tier headers (`## Tier A — ...`) become `meta.tier` on every item
beneath them, so a renderer can group items by tier or filter on tier.
Trailing sections `## Granted` and `## Superseded` (each containing
`(None yet.)` or actual items) preserve their headers as tiers too.
"""

import re
from typing import List, Dict, Any

from node_types.parsers import attach_default_actions


_ITEM_RE = re.compile(
    r"^- \*\*#(?P<num>\d+)\*\*\s*\[(?P<status>[^\]]+)\]\s*—\s*(?P<rest>.+?)\s*$"
)
_TIER_RE = re.compile(r"^##\s+(?P<tier>.+?)\s*$")


def parse(text: str) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    current_tier = ""

    for raw in text.splitlines():
        tier_match = _TIER_RE.match(raw)
        if tier_match:
            current_tier = tier_match.group("tier").strip()
            continue

        item_match = _ITEM_RE.match(raw)
        if not item_match:
            continue

        rest = item_match.group("rest")
        title, _, body = _split_title_body(rest)
        items.append(
            {
                "id": f"wish:{item_match.group('num')}",
                "title": title,
                "body": body,
                "status": item_match.group("status").strip(),
                "meta": {
                    "number": int(item_match.group("num")),
                    "tier": current_tier,
                },
            }
        )

    return attach_default_actions(items)


def _split_title_body(rest: str) -> tuple[str, str, str]:
    """Title is between the first **...**, body is whatever follows."""
    bold_match = re.match(r"\*\*(?P<title>[^*]+)\*\*\s*(?P<body>.*)$", rest)
    if bold_match:
        return bold_match.group("title").strip(), "", bold_match.group("body").strip()
    return rest.strip(), "", ""
