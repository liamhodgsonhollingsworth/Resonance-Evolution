"""
Workflow-from-within-Apeiron.

Closes the loop the design page named [Phase 3 — End-to-end chat-driven code
generation](../../design/workflow_from_within_apeiron.md#phase-3-end-to-end-chat-driven-code-generation-phase-0-1-dependency).
The Python entry point is `tools.workflow` (run as `python -m tools.workflow`);
the modules below implement the pieces:

- `session_manager` — spawn / send / resume / archive `claude` CLI subprocesses
  in stream-json mode. The Python sibling of the cockpit's SessionManager.
- `inbox` — file-based message queue. Compatible with the Alethea-cc inbox
  convention so messages port through the shared `nodes/` directory when
  available, fall back to local `state/inbox/` when not.
- `shell` — interactive REPL that boots the Apeiron engine + file-watcher,
  accepts user input, routes to sessions, and surfaces session output.

The workflow surface stays text-first: the shell is a CLI today; an
in-Apeiron 3D rendering of the same surface lands when the realtime renderer
(wishlist #023) does. The contract between user, sessions, and engine
matches the cockpit's primitives so a future cockpit refresh can subscribe
to the same engine.
"""

from .session_manager import SessionManager, SessionEvent, SessionRecord
from .inbox import Inbox, InboxMessage

__all__ = [
    "SessionManager",
    "SessionEvent",
    "SessionRecord",
    "Inbox",
    "InboxMessage",
]
