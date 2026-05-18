"""Tests for tools.workflow.inbox — file-based message queue."""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from tools.workflow.inbox import Inbox, InboxMessage, _parse_frontmatter


def test_post_and_read_roundtrip(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    path = inbox.post(
        to="agent_a",
        kind="task",
        summary="please-do-the-thing",
        body="more detail here",
        sender="workflow-shell",
    )
    assert path.exists()

    msgs = inbox.list_all()
    assert len(msgs) == 1
    msg = msgs[0]
    assert msg.to == "agent_a"
    assert msg.kind == "task"
    assert msg.summary == "please-do-the-thing"
    assert msg.sender == "workflow-shell"
    assert "more detail here" in msg.body


def test_list_for_filters_by_recipient(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(to="alice", kind="hi", summary="hello")
    inbox.post(to="bob", kind="hi", summary="hi-bob")
    inbox.post(to="alice", kind="reply", summary="reply to hello")

    alice_msgs = inbox.list_for("alice", unread_only=False)
    bob_msgs = inbox.list_for("bob", unread_only=False)
    assert len(alice_msgs) == 2
    assert len(bob_msgs) == 1


def test_mark_read_persists(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(to="x", kind="k", summary="s")
    msgs = inbox.list_all()
    assert msgs[0].read is False
    inbox.mark_read(msgs[0])
    # New inbox instance reading the same state dir picks up the mark.
    inbox2 = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    msgs2 = inbox2.list_all()
    assert msgs2[0].read is True


def test_unread_only_excludes_marked(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(to="x", kind="k", summary="first")
    inbox.post(to="x", kind="k", summary="second")
    all_msgs = inbox.list_all()
    inbox.mark_read(all_msgs[0])
    unread = inbox.list_all(unread_only=True)
    assert len(unread) == 1
    assert unread[0].summary == "second"


def test_connects_to_list_roundtrip(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(
        to="agent_b",
        kind="task",
        summary="follow-on",
        connects_to=["earlier_msg_1", "context_node_2"],
    )
    msgs = inbox.list_all()
    assert msgs[0].connects_to == ["earlier_msg_1", "context_node_2"]


def test_replies_to_threading(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(to="b", kind="task", summary="parent")
    inbox.post(to="b", kind="reply", summary="child", replies_to="inbox_msg_xyz.md")
    msgs = inbox.list_all()
    assert any(m.replies_to == "inbox_msg_xyz.md" for m in msgs)


def test_alethea_cc_routing_prefers_shared(tmp_path: Path):
    # Simulate an Alethea-cc checkout.
    cc_root = tmp_path / "Alethea-cc"
    (cc_root / "nodes").mkdir(parents=True)
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=cc_root)
    p_shared = inbox.post(to="x", kind="k", summary="shared", prefer_shared=True)
    p_local = inbox.post(to="x", kind="k", summary="local", prefer_shared=False)
    assert p_shared.parent == cc_root / "nodes"
    assert p_local.parent != cc_root / "nodes"
    # Both visible via list_all (it scans both dirs).
    summaries = {m.summary for m in inbox.list_all()}
    assert {"shared", "local"}.issubset(summaries)


def test_parse_frontmatter_quoted_scalar():
    fm = _parse_frontmatter('summary: "a: b: c"\nto: agent\n')
    assert fm["summary"] == "a: b: c"
    assert fm["to"] == "agent"


def test_parse_frontmatter_handles_yaml_list():
    fm = _parse_frontmatter("connects_to:\n  - one\n  - two\nfrom: x\n")
    assert fm["connects_to"] == ["one", "two"]
    assert fm["from"] == "x"


def test_yaml_inline_special_chars(tmp_path: Path):
    inbox = Inbox(state_dir=tmp_path, alethea_cc_root=None)
    inbox.post(to="x", kind="k", summary='has "quotes" and: colons')
    msgs = inbox.list_all()
    assert msgs[0].summary == 'has "quotes" and: colons'
