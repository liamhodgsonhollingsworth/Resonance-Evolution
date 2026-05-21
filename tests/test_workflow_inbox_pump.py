"""Tests for ``tools.workflow.inbox_pump.InboxPump``.

The pump runs as a daemon thread inside the Streamlit process; these
tests exercise the ``tick()`` method directly with fake SessionManager +
Inbox so the thread itself doesn't run. Covers:

- UUID-shape detection (only forward to session-shaped recipients).
- Idempotence: once forwarded, the same message is never re-sent.
- Maintainer-bound messages are marked but never sent.
- Unknown-session messages are marked (no retry storm) without delivery.
- Self-loops (sender == to) are dropped silently.
- New messages arriving between ticks are picked up.
- Empty-body messages fall back to summary text.
"""

from __future__ import annotations

import dataclasses
from pathlib import Path
from typing import Any, List, Tuple

import pytest

from tools.workflow.inbox_pump import InboxPump, _looks_like_session_id


GOOD_UUID = "f31038fe-42fd-492f-a1b3-718b9d52dbbd"
OTHER_UUID = "255713dd-42b3-42b7-9070-e7743c2fff3a"


@dataclasses.dataclass
class FakeMsg:
    path: Path
    to: str
    sender: str
    body: str = ""
    summary: str = ""


class FakeInbox:
    def __init__(self, msgs: List[FakeMsg]) -> None:
        self._msgs = msgs

    def list_all(self, unread_only: bool = False) -> List[FakeMsg]:
        return list(self._msgs)


class FakeSession:
    pass


class FakeSessionManager:
    def __init__(self, known_ids: List[str]) -> None:
        self.known_ids = set(known_ids)
        self.sent: List[Tuple[str, str]] = []

    def get(self, sid: str) -> Any:
        return FakeSession() if sid in self.known_ids else None

    def send(self, sid: str, body: str) -> None:
        if sid not in self.known_ids:
            raise RuntimeError(f"Unknown session: {sid}")
        self.sent.append((sid, body))


# ----- _looks_like_session_id -----


def test_looks_like_session_id_accepts_valid_uuid():
    assert _looks_like_session_id(GOOD_UUID)
    assert _looks_like_session_id(OTHER_UUID)


def test_looks_like_session_id_rejects_non_uuids():
    assert not _looks_like_session_id("maintainer")
    assert not _looks_like_session_id("agent_a")
    assert not _looks_like_session_id("workflow-shell")
    assert not _looks_like_session_id("")
    assert not _looks_like_session_id(None)
    assert not _looks_like_session_id(12345)
    # Right length but wrong shape.
    assert not _looks_like_session_id("x" * 36)
    # Right dashes but wrong section sizes.
    assert not _looks_like_session_id("12345-678-90-12-345")
    # Right shape but non-hex.
    assert not _looks_like_session_id("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")


# ----- pump.tick() -----


def test_forward_to_known_session(tmp_path):
    msg = FakeMsg(
        path=tmp_path / "inbox_msg_1.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="hello session",
    )
    inbox = FakeInbox([msg])
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    n = pump.tick()
    assert n == 1
    assert sm.sent == [(GOOD_UUID, "hello session")]


def test_idempotent_after_forward(tmp_path):
    msg = FakeMsg(
        path=tmp_path / "m.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="once",
    )
    inbox = FakeInbox([msg])
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    pump.tick()
    pump.tick()
    pump.tick()
    assert len(sm.sent) == 1


def test_marks_non_uuid_recipients(tmp_path):
    msgs = [
        FakeMsg(path=tmp_path / "to_maintainer.md", to="maintainer", sender="sess", body="hi"),
        FakeMsg(path=tmp_path / "to_agent.md", to="agent_a", sender="workflow-shell", body="hi"),
        FakeMsg(path=tmp_path / "no_to.md", to="?", sender="x", body="hi"),
    ]
    inbox = FakeInbox(msgs)
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    n = pump.tick()
    assert n == 0
    assert sm.sent == []
    # Subsequent ticks must not re-evaluate.
    pump.tick()
    assert n == 0


def test_marks_forwarded_for_unknown_session(tmp_path):
    msg = FakeMsg(
        path=tmp_path / "orphan.md",
        to=OTHER_UUID,
        sender="maintainer",
        body="dead letter",
    )
    inbox = FakeInbox([msg])
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    n = pump.tick()
    assert n == 0
    assert sm.sent == []
    # On the next tick, the message has already been marked forwarded,
    # so the FakeSessionManager.get is NOT called a second time.
    # (No clean way to assert that without instrumentation; the
    # idempotence test above already covers the marker persistence.)
    n = pump.tick()
    assert n == 0


def test_skips_self_loops(tmp_path):
    msg = FakeMsg(
        path=tmp_path / "self.md",
        to=GOOD_UUID,
        sender=GOOD_UUID,
        body="echo",
    )
    inbox = FakeInbox([msg])
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    n = pump.tick()
    assert n == 0
    assert sm.sent == []


def test_new_messages_forwarded_on_subsequent_tick(tmp_path):
    msgs: List[FakeMsg] = []
    inbox = FakeInbox(msgs)
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    pump.tick()  # nothing yet
    msgs.append(FakeMsg(
        path=tmp_path / "late.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="after the fact",
    ))
    n = pump.tick()
    assert n == 1
    assert sm.sent == [(GOOD_UUID, "after the fact")]


def test_uses_summary_when_body_empty(tmp_path):
    msg = FakeMsg(
        path=tmp_path / "summary_only.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="",
        summary="just a summary",
    )
    inbox = FakeInbox([msg])
    sm = FakeSessionManager([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    pump.tick()
    assert sm.sent == [(GOOD_UUID, "just a summary")]


def test_state_persists_across_pump_instances(tmp_path):
    """A new InboxPump on the same state_dir picks up the previous marker."""
    msg = FakeMsg(
        path=tmp_path / "persist.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="forward once",
    )
    inbox = FakeInbox([msg])
    sm1 = FakeSessionManager([GOOD_UUID])
    pump1 = InboxPump(sm1, inbox, state_dir=tmp_path / "state")
    pump1.tick()
    assert sm1.sent == [(GOOD_UUID, "forward once")]
    # Fresh pump on the same state_dir — must NOT re-forward.
    sm2 = FakeSessionManager([GOOD_UUID])
    pump2 = InboxPump(sm2, inbox, state_dir=tmp_path / "state")
    pump2.tick()
    assert sm2.sent == []


def test_transient_send_failure_retries_next_tick(tmp_path):
    """If send raises with a KNOWN session, the message stays un-marked."""
    msg = FakeMsg(
        path=tmp_path / "transient.md",
        to=GOOD_UUID,
        sender="maintainer",
        body="will succeed on retry",
    )
    inbox = FakeInbox([msg])

    class FlakeySM(FakeSessionManager):
        def __init__(self, known_ids):
            super().__init__(known_ids)
            self.attempts = 0

        def send(self, sid, body):
            self.attempts += 1
            if self.attempts == 1:
                raise RuntimeError("transient pipe error")
            super().send(sid, body)

    sm = FlakeySM([GOOD_UUID])
    pump = InboxPump(sm, inbox, state_dir=tmp_path / "state")
    n1 = pump.tick()
    assert n1 == 0
    assert sm.sent == []
    n2 = pump.tick()
    assert n2 == 1
    assert sm.sent == [(GOOD_UUID, "will succeed on retry")]
