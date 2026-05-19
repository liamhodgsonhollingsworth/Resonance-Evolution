"""
Inbox — file-based message queue.

Wire-compatible with the Alethea-cc convention at
[Alethea-cc/nodes/inbox_msg_*.md](https://github.com/liamhodgsonhollingsworth/Alethea/tree/main/Alethea-cc/nodes):
each message is a Markdown file with YAML frontmatter (`to:`, `from:`,
`kind:`, `summary:`, `connects_to:`, optionally `replies_to:`), one
message per file, filenames carry the timestamp for ordering.

When an Alethea-cc checkout is detected on the same machine, the inbox
reads and writes there directly so messages flow between Apeiron sessions
and any other tools watching the shared directory. When no Alethea-cc
checkout is present, the inbox falls back to `state/inbox/` under the
workflow shell's state directory so the shell still works standalone.

This is the SAME mechanism Apeiron sessions use to communicate with
their own subagents — a subagent of a session writes an inbox message,
the workflow shell sees it, routes it. The session-to-subagent and
shell-to-session paths share one transport; the difference is only the
processing step (a session reads via its MCP-tool wrapper; the shell
reads via this module's `read()`).
"""

from __future__ import annotations

import os
import re
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .trust import TrustSet  # noqa: F401


# ----- public types -----


@dataclass
class InboxMessage:
    path: Path
    to: str
    sender: str
    kind: str
    summary: str
    body: str = ""
    connects_to: List[str] = field(default_factory=list)
    replies_to: Optional[str] = None
    ts: float = 0.0  # mtime of the file, set on read
    read: bool = False


# ----- Inbox -----


_DETECT = object()  # sentinel: "auto-detect alethea-cc"


class Inbox:
    """File-based message bus.

    `alethea_cc_root`:
      - omitted (default sentinel) → auto-detect a sibling Alethea-cc/nodes/.
      - None → explicitly skip the shared dir; only the local state_dir is used.
      - Path → use this path's `nodes/` subdirectory as the shared dir.

    `sender_trust` (optional): a ``TrustSet`` consulted by ``list_main`` /
    ``list_quarantine`` so untrusted-sender messages route to a separate
    surface (SPEC-057). The legacy ``list_all`` / ``list_for`` keep
    pre-trust behavior (no filter) — they are still used by tests + tools
    that want the unfiltered view.

    `session_trust` (optional): a separate ``TrustSet`` consulted by
    ``list_for_session`` so messages addressed to a running session are
    filtered by who is allowed to message that session. Initial default:
    the maintainer only. SPEC-059.
    """

    def __init__(
        self,
        state_dir: Path,
        alethea_cc_root=_DETECT,
        sender_trust: Any = None,
        session_trust: Any = None,
    ):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.local_dir = self.state_dir / "inbox"
        self.local_dir.mkdir(exist_ok=True)
        self.read_marker = self.state_dir / "inbox_read.txt"
        if alethea_cc_root is _DETECT:
            alethea_cc_root = _detect_alethea_cc()
        self.alethea_cc_inbox = (
            (alethea_cc_root / "nodes") if alethea_cc_root else None
        )
        self.sender_trust = sender_trust
        self.session_trust = session_trust

    # ----- writing -----

    def post(
        self,
        to: str,
        kind: str,
        summary: str,
        body: str = "",
        sender: str = "workflow-shell",
        connects_to: Optional[List[str]] = None,
        replies_to: Optional[str] = None,
        prefer_shared: bool = True,
    ) -> Path:
        """Write a new message. Returns the path written.

        prefer_shared: when True and Alethea-cc is available, write into
        the shared `nodes/` directory; otherwise local. Setting False
        forces local-only (useful for shell-internal messages that should
        not show up in Alethea-cc's view).
        """
        ts = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
        slug = _slugify(summary or kind)
        fname = f"inbox_msg_{ts}_{slug}_{uuid.uuid4().hex[:8]}.md"

        target_dir = (
            self.alethea_cc_inbox
            if prefer_shared and self.alethea_cc_inbox and self.alethea_cc_inbox.exists()
            else self.local_dir
        )
        target_dir.mkdir(parents=True, exist_ok=True)

        path = target_dir / fname
        path.write_text(_format_message(
            to=to,
            sender=sender,
            kind=kind,
            summary=summary,
            connects_to=connects_to or [],
            replies_to=replies_to,
            body=body,
        ), encoding="utf-8")
        return path

    # ----- reading -----

    def list_all(self, unread_only: bool = False) -> List[InboxMessage]:
        """Return every visible message, newest last."""
        read_paths = self._load_read_set()
        out: List[InboxMessage] = []
        for d in self._scan_dirs():
            for path in sorted(d.glob("inbox_msg_*.md")):
                try:
                    msg = _parse_message(path)
                    msg.read = str(path) in read_paths
                    if unread_only and msg.read:
                        continue
                    out.append(msg)
                except Exception:
                    continue
        out.sort(key=lambda m: (m.ts, str(m.path)))
        return out

    def list_for(self, recipient: str, unread_only: bool = True) -> List[InboxMessage]:
        return [m for m in self.list_all(unread_only=unread_only) if m.to == recipient]

    def list_main(self, unread_only: bool = False) -> List[InboxMessage]:
        """Messages from trusted senders only (SPEC-057).

        When no ``sender_trust`` is configured the call falls through to
        ``list_all`` so legacy callers continue to work.
        """
        if self.sender_trust is None:
            return self.list_all(unread_only=unread_only)
        return [
            m for m in self.list_all(unread_only=unread_only)
            if self.sender_trust.is_trusted(m.sender)
        ]

    def list_quarantine(self, unread_only: bool = False) -> List[InboxMessage]:
        """Messages from untrusted senders only (SPEC-057 / SPEC-058).

        When no ``sender_trust`` is configured the quarantine is empty by
        definition — without a trust-set there is no notion of untrusted.
        """
        if self.sender_trust is None:
            return []
        return [
            m for m in self.list_all(unread_only=unread_only)
            if not self.sender_trust.is_trusted(m.sender)
        ]

    def is_sender_trusted(self, sender: str) -> bool:
        """Convenience: returns True when no trust-set is configured."""
        if self.sender_trust is None:
            return True
        return self.sender_trust.is_trusted(sender)

    def partition_main_quarantine(
        self,
        unread_only: bool = False,
    ) -> "tuple[List[InboxMessage], List[InboxMessage]]":
        """Single-pass walk that returns (main, quarantine).

        list_main + list_quarantine both call list_all which is O(N) in
        file I/O. Callers that want both surfaces should use this method
        to avoid the double walk.
        """
        all_msgs = self.list_all(unread_only=unread_only)
        if self.sender_trust is None:
            return all_msgs, []
        main: List[InboxMessage] = []
        quar: List[InboxMessage] = []
        for m in all_msgs:
            if self.sender_trust.is_trusted(m.sender):
                main.append(m)
            else:
                quar.append(m)
        return main, quar

    def list_for_session(
        self,
        session_id: str,
        unread_only: bool = False,
    ) -> List[InboxMessage]:
        """Messages addressed to ``session_id`` from session-trusted senders only (SPEC-059).

        When no ``session_trust`` is configured, falls through to
        ``list_for(session_id)`` so legacy callers stay correct.
        """
        msgs = self.list_for(session_id, unread_only=unread_only)
        if self.session_trust is None:
            return msgs
        return [m for m in msgs if self.session_trust.is_trusted(m.sender)]

    def list_for_session_quarantine(
        self,
        session_id: str,
        unread_only: bool = False,
    ) -> List[InboxMessage]:
        """Messages addressed to ``session_id`` from session-UNtrusted senders.

        Empty when no ``session_trust`` is configured (no notion of
        untrusted-for-session without a trust-set).
        """
        if self.session_trust is None:
            return []
        msgs = self.list_for(session_id, unread_only=unread_only)
        return [m for m in msgs if not self.session_trust.is_trusted(m.sender)]

    def is_sender_trusted_for_session(self, sender: str) -> bool:
        """True when no session-trust-set is configured (legacy passthrough)."""
        if self.session_trust is None:
            return True
        return self.session_trust.is_trusted(sender)

    def mark_read(self, msg: InboxMessage) -> None:
        s = self._load_read_set()
        s.add(str(msg.path))
        self._save_read_set(s)
        msg.read = True

    def mark_all_read(self, msgs: List[InboxMessage]) -> None:
        s = self._load_read_set()
        for m in msgs:
            s.add(str(m.path))
            m.read = True
        self._save_read_set(s)

    def watched_dirs(self) -> List[Path]:
        return [d for d in self._scan_dirs()]

    # ----- internals -----

    def _scan_dirs(self) -> List[Path]:
        dirs: List[Path] = [self.local_dir]
        if self.alethea_cc_inbox and self.alethea_cc_inbox.exists():
            dirs.append(self.alethea_cc_inbox)
        return dirs

    def _load_read_set(self) -> set:
        if not self.read_marker.exists():
            return set()
        try:
            return {
                line.strip()
                for line in self.read_marker.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        except Exception:
            return set()

    def _save_read_set(self, s: set) -> None:
        try:
            self.read_marker.write_text("\n".join(sorted(s)) + "\n", encoding="utf-8")
        except Exception:
            pass


# ----- helpers -----


_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)


def _format_message(
    *,
    to: str,
    sender: str,
    kind: str,
    summary: str,
    connects_to: List[str],
    replies_to: Optional[str],
    body: str,
) -> str:
    lines = ["---"]
    lines.append(f"to: {to}")
    lines.append(f"from: {sender}")
    lines.append(f"kind: {kind}")
    lines.append(f"summary: {_yaml_inline(summary)}")
    if connects_to:
        lines.append("connects_to:")
        for c in connects_to:
            lines.append(f"  - {c}")
    if replies_to:
        lines.append(f"replies_to: {replies_to}")
    lines.append("---")
    lines.append("")
    lines.append(body or "")
    return "\n".join(lines) + "\n"


def _yaml_inline(s: str) -> str:
    """Render a single-line YAML scalar safely."""
    s = (s or "").replace("\n", " ").strip()
    if not s:
        return '""'
    if any(c in s for c in ":#\"'`{}[]&*?|<>=!%@,"):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def _parse_message(path: Path) -> InboxMessage:
    text = path.read_text(encoding="utf-8", errors="replace")
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return InboxMessage(
            path=path,
            to="?",
            sender="?",
            kind="?",
            summary=path.name,
            body=text,
            ts=path.stat().st_mtime,
        )
    fm_text, body = m.group(1), m.group(2)
    fm = _parse_frontmatter(fm_text)
    return InboxMessage(
        path=path,
        to=str(fm.get("to", "?")),
        sender=str(fm.get("from", "?")),
        kind=str(fm.get("kind", "?")),
        summary=str(fm.get("summary", path.name)),
        body=body.lstrip("\n"),
        connects_to=[str(x) for x in fm.get("connects_to", []) if x],
        replies_to=fm.get("replies_to"),
        ts=path.stat().st_mtime,
    )


def _parse_frontmatter(text: str) -> Dict[str, Any]:
    """
    Minimal YAML-like parser for the constrained subset the inbox uses.

    Handles:
      key: value
      key: "quoted value"
      key:
        - item1
        - item2
    """
    out: Dict[str, Any] = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if not line.strip():
            i += 1
            continue
        if ":" not in line:
            i += 1
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        rest = rest.strip()
        if rest:
            out[key] = _unyaml_scalar(rest)
            i += 1
            continue
        # multi-line list
        items: List[str] = []
        i += 1
        while i < len(lines):
            sub = lines[i]
            stripped = sub.lstrip()
            if not stripped:
                break
            if not stripped.startswith("-"):
                break
            items.append(stripped.lstrip("-").strip())
            i += 1
        out[key] = items
    return out


def _unyaml_scalar(s: str) -> Any:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        return s[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if s.lower() in ("null", "~", ""):
        return None
    if s.lower() == "true":
        return True
    if s.lower() == "false":
        return False
    return s


def _slugify(s: str, max_len: int = 40) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", s.strip()).strip("_").lower()
    if len(s) > max_len:
        s = s[:max_len].rstrip("_")
    return s or "msg"


def _detect_alethea_cc() -> Optional[Path]:
    """
    Locate the Alethea-cc checkout the maintainer uses for inbox messages.

    Strategy:
    1. Honor `ALETHEA_CC_ROOT` env var if set.
    2. Try the canonical maintainer path on Windows.
    3. Walk upward from cwd looking for `Alethea-cc/nodes/`.
    """
    explicit = os.environ.get("ALETHEA_CC_ROOT")
    if explicit:
        p = Path(explicit)
        if p.exists():
            return p

    candidates = [
        Path(r"C:/Users/Liam/Desktop/Alethea/Alethea-cc"),
        Path("/Users/Liam/Desktop/Alethea/Alethea-cc"),
        Path.home() / "Desktop/Alethea/Alethea-cc",
    ]
    for p in candidates:
        if (p / "nodes").exists():
            return p

    # Walk upward looking for an Alethea-cc/nodes sibling.
    cur = Path.cwd().resolve()
    for parent in [cur, *cur.parents]:
        candidate = parent / "Alethea-cc" / "nodes"
        if candidate.exists():
            return parent / "Alethea-cc"

    return None
