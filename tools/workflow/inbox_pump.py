"""Inbox pump — forward inbox files addressed to running sessions into stdin.

The Streamlit chat panel forwards typed text via ``SessionManager.send()``,
so GUI-typed messages reach the spawned ``claude`` subprocess's stdin pipe
and the session can act on them. But inbox messages written DIRECTLY to
``Alethea-cc/nodes/inbox_msg_*.md`` (by the maintainer in another window,
by a sibling session, or by any tool that just writes files) never reach
the spawned session unless something polls the dir and forwards new files.

This module is that polling daemon. It runs as a background daemon thread
inside the Streamlit process (or any consumer that owns a SessionManager +
Inbox pair) and on every tick:

1. ``inbox.list_all()`` to see every visible message.
2. For each message whose ``to:`` is a UUID-shaped string (i.e. addressed
   to a session), is not in the forwarded-set, and whose ``sender != to``
   (skip self-loops):
   - Look up the session via ``session_manager.get(to)``.
   - If known: call ``session_manager.send(to, body)``. On success, mark
     forwarded. On any send-exception, leave un-marked so the next tick
     retries (e.g. transient pipe errors).
   - If unknown: mark forwarded so we don't re-evaluate the message
     every tick (no recipient to deliver to).
3. For each message whose ``to:`` is NOT a session-id-shaped string
   (``maintainer``, ``agent_a``, ``workflow-shell``, etc.): mark forwarded
   so it's not re-evaluated. These are display-side messages the chat
   panel renders directly.

Forwarded state persists at ``state/workflow/inbox_forwarded.txt`` so a
streamlit restart picks up where the previous one left off.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path
from typing import Any, Optional, Set


logger = logging.getLogger(__name__)


def _looks_like_session_id(s: Any) -> bool:
    """A SessionManager session id is a uuid4 string: 36 chars, 4 dashes."""
    if not isinstance(s, str):
        return False
    if len(s) != 36 or s.count("-") != 4:
        return False
    parts = s.split("-")
    expected = (8, 4, 4, 4, 12)
    if tuple(len(p) for p in parts) != expected:
        return False
    return all(c in "0123456789abcdefABCDEF" for p in parts for c in p)


class InboxPump:
    """Drain inbox files addressed to active sessions into their stdin."""

    def __init__(
        self,
        session_manager: Any,
        inbox: Any,
        state_dir: Path,
        poll_interval: float = 2.0,
    ):
        self.session_manager = session_manager
        self.inbox = inbox
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.forwarded_marker = self.state_dir / "inbox_forwarded.txt"
        self.poll_interval = poll_interval
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception as exc:  # pragma: no cover — daemon resilience
                logger.warning("inbox-pump tick failed: %s", exc)
            self._stop.wait(self.poll_interval)

    def tick(self) -> int:
        """Forward any new addressed-to-session messages.

        Returns the count of messages forwarded this tick (for tests).
        """
        forwarded = self._load_forwarded()
        try:
            msgs = self.inbox.list_all(unread_only=False)
        except Exception as exc:
            logger.warning("inbox-pump list_all failed: %s", exc)
            return 0
        n_sent = 0
        dirty = False
        for msg in msgs:
            path_key = str(msg.path)
            if path_key in forwarded:
                continue
            if not _looks_like_session_id(msg.to):
                # Maintainer-bound, shell-bound, etc. — chat panel renders
                # these. Mark forwarded so we never re-evaluate.
                forwarded.add(path_key)
                dirty = True
                continue
            if msg.sender == msg.to:
                # Session messaging itself — silently drop to avoid loops.
                forwarded.add(path_key)
                dirty = True
                continue
            recipient_known = self._session_known(msg.to)
            if not recipient_known:
                logger.info(
                    "inbox-pump dropping %s — no session %s",
                    msg.path.name, msg.to,
                )
                forwarded.add(path_key)
                dirty = True
                continue
            sent = self._forward(msg)
            if sent:
                n_sent += 1
                forwarded.add(path_key)
                dirty = True
            # On send failure with a known session, leave un-marked so the
            # next tick retries (e.g. transient BrokenPipe before relaunch).
        if dirty:
            self._save_forwarded(forwarded)
        return n_sent

    def _forward(self, msg: Any) -> bool:
        body = (msg.body or "").strip()
        if not body:
            body = msg.summary or "(empty message)"
        try:
            self.session_manager.send(msg.to, body)
            return True
        except Exception as exc:
            logger.info(
                "inbox-pump could not forward %s to %s: %s",
                msg.path.name, msg.to, exc,
            )
            return False

    def _session_known(self, session_id: str) -> bool:
        try:
            rec = self.session_manager.get(session_id)
        except Exception:
            return False
        return rec is not None

    def _load_forwarded(self) -> Set[str]:
        if not self.forwarded_marker.exists():
            return set()
        try:
            return {
                line.strip()
                for line in self.forwarded_marker.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        except Exception:
            return set()

    def _save_forwarded(self, s: Set[str]) -> None:
        try:
            self.forwarded_marker.write_text(
                "\n".join(sorted(s)) + "\n", encoding="utf-8"
            )
        except Exception:
            pass
