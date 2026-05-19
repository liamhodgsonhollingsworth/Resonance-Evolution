"""
Tests for SPEC-059: session-messaging gated by trust.

Sessions running on the maintainer's machine accept inbox messages only
from senders in the session-trust-set. Default trust-set is the
authenticated maintainer only; other senders route to a session-scoped
quarantine surface for maintainer review.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.workflow.inbox import Inbox
from tools.workflow.trust import sender_trust_set, session_trust_set


def _post(inbox: Inbox, to: str, sender: str, summary: str) -> None:
    inbox.post(to=to, kind="msg", summary=summary, sender=sender)


def test_no_session_trust_falls_back_to_list_for(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    _post(inbox, to="session-x", sender="LHH", summary="hi")
    _post(inbox, to="session-x", sender="random", summary="hi")
    msgs = inbox.list_for_session("session-x")
    assert len(msgs) == 2
    assert inbox.list_for_session_quarantine("session-x") == []


def test_session_trust_only_lets_maintainer_through(tmp_path: Path):
    sts = session_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None, session_trust=sts)
    _post(inbox, to="session-x", sender="LHH", summary="from-maintainer")
    _post(inbox, to="session-x", sender="workflow-shell", summary="from-shell")
    _post(inbox, to="session-x", sender="random-worker", summary="from-random")

    msgs = inbox.list_for_session("session-x")
    assert {m.sender for m in msgs} == {"LHH"}

    quar = inbox.list_for_session_quarantine("session-x")
    assert {m.sender for m in quar} == {"workflow-shell", "random-worker"}


def test_session_and_main_trust_sets_are_independent(tmp_path: Path):
    """SPEC-059 says session-trust-set and sender-trust-set are distinct.
    A sender can be trusted for the maintainer's inbox but not for
    sessions, or vice versa. Here ``workflow-shell`` is in the maintainer's
    trust-set (default) but NOT in the session-trust-set (only LHH).
    """
    sts = session_trust_set(tmp_path, user="LHH")
    senders_ts = sender_trust_set(tmp_path / "alt", user="LHH")
    inbox = Inbox(
        state_dir=tmp_path / "state",
        alethea_cc_root=None,
        sender_trust=senders_ts,
        session_trust=sts,
    )
    _post(inbox, to="LHH", sender="workflow-shell", summary="for-maintainer")
    _post(inbox, to="session-x", sender="workflow-shell", summary="for-session")

    # Maintainer's trust-set includes workflow-shell, so both messages
    # appear in list_main (which filters only by from, not by to).
    assert {m.sender for m in inbox.list_main()} == {"workflow-shell"}
    assert inbox.list_quarantine() == []

    # But session-trust-set does NOT include workflow-shell, so the
    # session sees nothing in its main + the message routes to its
    # session-quarantine.
    session_msgs = inbox.list_for_session("session-x")
    assert session_msgs == []
    session_quar = inbox.list_for_session_quarantine("session-x")
    assert len(session_quar) == 1
    assert session_quar[0].summary == "for-session"


def test_promote_for_sessions_independent_of_maintainer_trust(tmp_path: Path):
    sts = session_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None, session_trust=sts)

    _post(inbox, to="session-x", sender="trusted-worker", summary="hi-from-worker")

    assert inbox.list_for_session("session-x") == []
    sts.add("trusted-worker")
    msgs = inbox.list_for_session("session-x")
    assert {m.sender for m in msgs} == {"LHH", "trusted-worker"} or {m.sender for m in msgs} == {"trusted-worker"}
    assert "trusted-worker" in {m.sender for m in msgs}


def test_session_for_different_recipient_does_not_leak(tmp_path: Path):
    sts = session_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None, session_trust=sts)
    _post(inbox, to="session-x", sender="LHH", summary="for-x")
    _post(inbox, to="session-y", sender="LHH", summary="for-y")

    x_msgs = inbox.list_for_session("session-x")
    assert {m.summary for m in x_msgs} == {"for-x"}

    y_msgs = inbox.list_for_session("session-y")
    assert {m.summary for m in y_msgs} == {"for-y"}


def test_is_sender_trusted_for_session_legacy_true(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    assert inbox.is_sender_trusted_for_session("anyone")


def test_is_sender_trusted_for_session_consults_trust(tmp_path: Path):
    sts = session_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None, session_trust=sts)
    assert inbox.is_sender_trusted_for_session("LHH")
    assert not inbox.is_sender_trusted_for_session("attacker")
