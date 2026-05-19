"""
Tests for SPEC-057: trusted-sender messaging filter.

Verifies that the inbox's ``list_main`` / ``list_quarantine`` surfaces
correctly partition messages by sender against a ``TrustSet``, and that
legacy callers (``list_all`` / ``list_for``) remain unfiltered.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.workflow.inbox import Inbox
from tools.workflow.trust import sender_trust_set, TrustSet


@pytest.fixture
def inbox_path(tmp_path: Path) -> Path:
    return tmp_path / "state"


def _post(inbox: Inbox, sender: str, summary: str) -> None:
    inbox.post(to="LHH", kind="msg", summary=summary, sender=sender)


def test_no_sender_trust_falls_back_to_list_all(inbox_path: Path):
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=None)
    _post(inbox, sender="alice", summary="hello")
    _post(inbox, sender="bob", summary="world")
    assert len(inbox.list_main()) == 2
    assert inbox.list_quarantine() == []


def test_trusted_sender_messages_go_to_main(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="LHH", summary="from-maintainer")
    _post(inbox, sender="workflow-shell", summary="from-shell")
    msgs = inbox.list_main()
    summaries = {m.summary for m in msgs}
    assert summaries == {"from-maintainer", "from-shell"}
    assert inbox.list_quarantine() == []


def test_untrusted_sender_messages_go_to_quarantine(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="attacker", summary="malicious")
    _post(inbox, sender="unknown-worker", summary="hello")
    assert inbox.list_main() == []
    quarantine = inbox.list_quarantine()
    assert {m.sender for m in quarantine} == {"attacker", "unknown-worker"}


def test_mixed_messages_partition_correctly(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="LHH", summary="trusted-1")
    _post(inbox, sender="attacker", summary="untrusted-1")
    _post(inbox, sender="workflow-shell", summary="trusted-2")
    _post(inbox, sender="random-worker", summary="untrusted-2")

    main = inbox.list_main()
    quar = inbox.list_quarantine()
    assert {m.summary for m in main} == {"trusted-1", "trusted-2"}
    assert {m.summary for m in quar} == {"untrusted-1", "untrusted-2"}

    # list_all is unfiltered.
    assert len(inbox.list_all()) == 4


def test_promoting_sender_moves_message_to_main(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="prospective-worker", summary="initial-message")

    assert inbox.list_main() == []
    assert len(inbox.list_quarantine()) == 1

    ts.add("prospective-worker")

    main = inbox.list_main()
    assert len(main) == 1
    assert main[0].sender == "prospective-worker"
    assert inbox.list_quarantine() == []


def test_is_sender_trusted_legacy_true_when_no_trust(inbox_path: Path):
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=None)
    assert inbox.is_sender_trusted("anyone")


def test_is_sender_trusted_consults_trust_set(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    assert inbox.is_sender_trusted("LHH")
    assert inbox.is_sender_trusted("workflow-shell")
    assert not inbox.is_sender_trusted("attacker")


def test_unread_only_compose_with_filter(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="LHH", summary="trusted-msg")
    _post(inbox, sender="attacker", summary="untrusted-msg")

    main_msgs = inbox.list_main(unread_only=True)
    assert len(main_msgs) == 1
    inbox.mark_read(main_msgs[0])

    main_unread = inbox.list_main(unread_only=True)
    assert main_unread == []
    quar_unread = inbox.list_quarantine(unread_only=True)
    assert len(quar_unread) == 1


def test_list_for_recipient_does_not_filter_by_sender(inbox_path: Path, tmp_path: Path):
    """list_for is the legacy recipient-filter; it intentionally does NOT
    apply sender-trust so existing tools that poll for a given recipient
    keep their behavior. Callers that want trust-filtering use list_main."""
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="LHH", summary="trusted")
    _post(inbox, sender="attacker", summary="untrusted")
    msgs = inbox.list_for("LHH", unread_only=False)
    assert len(msgs) == 2  # unfiltered by sender


def test_empty_sender_field_treated_as_untrusted(inbox_path: Path, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=inbox_path, alethea_cc_root=None, sender_trust=ts)
    _post(inbox, sender="", summary="anonymous")
    assert inbox.list_main() == []
    assert len(inbox.list_quarantine()) == 1
