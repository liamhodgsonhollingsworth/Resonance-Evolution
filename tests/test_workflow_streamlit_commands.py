"""Headless stress tests — exercise every registered command + the CLI bridge.

Bypasses Streamlit entirely: constructs a CommandRegistry, runs each
command's handler against a temporary state directory, and verifies
side effects on disk + the in-memory engine cache.

The same handlers run in the live Streamlit page; passing here means
the equivalent button click in the GUI works too, because the panel
just dispatches to ``registry.run_gui`` which calls the same handler.
"""

from __future__ import annotations

import shlex
from pathlib import Path
from typing import List

import pytest

from engine.core import Engine
from tools.workflow_streamlit.cli_bridge import drain, enqueue, queue_path
from tools.workflow_streamlit.command_registry import CommandContext, CommandRegistry
from tools.workflow_streamlit.commands import register_all
from tools.workflow_streamlit.config import RuntimeConfig


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


REPO_ROOT = Path(__file__).resolve().parents[1]


class _FakeSessionRecord:
    def __init__(self, sid: str, status: str = "idle"):
        self.id = sid
        self.display_name = "fake-session"
        self.session_type = "workflow-management"
        self.status = status


class _FakeSessionManager:
    def __init__(self):
        self.sent: List[tuple[str, str]] = []
        self._records = {"sess-fake-001": _FakeSessionRecord("sess-fake-001", "active")}

    def list(self):
        return list(self._records.values())

    def get(self, sid):
        return self._records.get(sid)

    def send(self, sid, body):
        self.sent.append((sid, body))


class _FakeInboxMessage:
    def __init__(self, sender, to, summary, body, ts):
        self.sender = sender
        self.to = to
        self.summary = summary
        self.body = body
        self.ts = ts
        self.kind = "chat"
        self.path = Path(f"/fake/inbox/{summary[:20]}.md")
        self.read = False
        self.connects_to: List[str] = []
        self.replies_to = None


class _FakeInbox:
    def __init__(self):
        self._msgs: List[_FakeInboxMessage] = []

    def post(self, to, kind, summary, body, sender="workflow-shell", connects_to=None, replies_to=None, prefer_shared=True):
        import time as _t
        msg = _FakeInboxMessage(sender=sender, to=to, summary=summary, body=body, ts=_t.time())
        self._msgs.append(msg)
        return msg.path

    def list_all(self, unread_only=False):
        return list(self._msgs)


@pytest.fixture
def runtime(tmp_path):
    state_dir = tmp_path / "state" / "workflow"
    state_dir.mkdir(parents=True, exist_ok=True)
    cfg = RuntimeConfig(
        apeiron_root=REPO_ROOT,
        require_login=False,
        local_user="LHH",
        accounts_path=tmp_path / "accounts.json",
        state_dir=state_dir,
        default_scene="workflow_view.json",
    )
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = REPO_ROOT / "scenes" / "workflow_view.json"
    if scene.exists():
        engine.load_scene(scene)
        engine.precompute()
    sm = _FakeSessionManager()
    inbox = _FakeInbox()
    registry = CommandRegistry()
    register_all(registry)
    ctx = CommandContext(
        engine=engine,
        session_manager=sm,
        inbox=inbox,
        file_watcher=None,
        config=cfg,
        apeiron_root=REPO_ROOT,
        active_session_id="sess-fake-001",
        user="LHH",
    )
    return {"cfg": cfg, "registry": registry, "ctx": ctx, "sm": sm, "inbox": inbox, "engine": engine}


# ---------------------------------------------------------------------------
# Meta + ping
# ---------------------------------------------------------------------------


def test_ping_command(runtime):
    result = runtime["registry"].run("ping hello world", runtime["ctx"])
    assert result.ok and "pong" in result.message and "hello world" in result.message


def test_echo_command(runtime):
    result = runtime["registry"].run("echo foo bar", runtime["ctx"])
    assert result.ok and result.message == "foo bar"


def test_help_lists_every_command(runtime):
    result = runtime["registry"].run("help", runtime["ctx"])
    assert result.ok
    names = result.data
    expected = {
        "ping", "echo", "help", "clear",
        "idea-queue.list", "idea-queue.add", "idea-queue.up",
        "idea-queue.down", "idea-queue.delete",
        "session.status", "session.list", "session.respawn",
        "scene.list", "scene.load", "scene.current",
        "items.list", "items.show",
        "chat.send", "chat.list",
    }
    assert expected.issubset(set(names)), f"missing: {expected - set(names)}"


def test_help_for_specific_command(runtime):
    result = runtime["registry"].run("help idea-queue.add", runtime["ctx"])
    assert result.ok and "idea-queue.add" in result.message and "<text" in result.message


def test_unknown_command_errors_cleanly(runtime):
    result = runtime["registry"].run("nopenopenope", runtime["ctx"])
    assert not result.ok and "unknown command" in result.message


def test_clear_empties_the_log(runtime):
    runtime["registry"].run("ping a", runtime["ctx"])
    runtime["registry"].run("ping b", runtime["ctx"])
    assert len(runtime["registry"].log()) >= 2
    runtime["registry"].run("clear", runtime["ctx"])
    # clear's own entry is then logged; so length is 1 right after.
    assert len(runtime["registry"].log()) <= 1


# ---------------------------------------------------------------------------
# Idea queue — full CRUD lifecycle
# ---------------------------------------------------------------------------


def test_idea_queue_lifecycle(runtime):
    reg = runtime["registry"]
    ctx = runtime["ctx"]
    # Empty list.
    r = reg.run("idea-queue.list", ctx)
    assert r.ok and r.data == []
    # Add three.
    reg.run('idea-queue.add "fix the oscillation"', ctx)
    reg.run('idea-queue.add "stress test every panel"', ctx)
    reg.run('idea-queue.add "write the CLI bridge"', ctx)
    r = reg.run("idea-queue.list", ctx)
    assert r.ok and len(r.data) == 3 and "fix the oscillation" == r.data[0]
    # Swap 0 with 1 via down.
    reg.run("idea-queue.down 0", ctx)
    r = reg.run("idea-queue.list", ctx)
    assert r.data[0] == "stress test every panel"
    # Move it back up.
    reg.run("idea-queue.up 1", ctx)
    r = reg.run("idea-queue.list", ctx)
    assert r.data[0] == "fix the oscillation"
    # Delete middle.
    reg.run("idea-queue.delete 1", ctx)
    r = reg.run("idea-queue.list", ctx)
    assert len(r.data) == 2 and "stress test every panel" not in r.data


def test_idea_queue_out_of_range_errors(runtime):
    reg = runtime["registry"]
    ctx = runtime["ctx"]
    r = reg.run("idea-queue.up 9999", ctx)
    assert not r.ok and "range" in r.message
    r = reg.run("idea-queue.delete 0", ctx)
    assert not r.ok and "range" in r.message


def test_idea_queue_add_rejects_empty(runtime):
    r = runtime["registry"].run('idea-queue.add ""', runtime["ctx"])
    assert not r.ok and "empty" in r.message.lower()


# ---------------------------------------------------------------------------
# Scene
# ---------------------------------------------------------------------------


def test_scene_list_includes_workflow_view(runtime):
    r = runtime["registry"].run("scene.list", runtime["ctx"])
    assert r.ok and "workflow_view.json" in r.data


def test_scene_load_works_then_current_reports_it(runtime):
    reg = runtime["registry"]
    ctx = runtime["ctx"]
    r = reg.run("scene.load workflow_view.json", ctx)
    assert r.ok and "workflow_view.json" in r.message
    cur = reg.run("scene.current", ctx)
    assert cur.ok and cur.data == "workflow_view.json"


def test_scene_load_handles_bare_name_without_json(runtime):
    r = runtime["registry"].run("scene.load workflow_view", runtime["ctx"])
    assert r.ok, f"expected ok, got: {r.message}"


def test_scene_load_missing_errors(runtime):
    r = runtime["registry"].run("scene.load no-such-scene", runtime["ctx"])
    assert not r.ok and "not found" in r.message


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


def test_session_status_active(runtime):
    r = runtime["registry"].run("session.status", runtime["ctx"])
    assert r.ok and "sess-fak" in r.message


def test_session_list_returns_records(runtime):
    r = runtime["registry"].run("session.list", runtime["ctx"])
    assert r.ok and "sess-fake-001" in r.data


def test_session_respawn_sets_scratch_flag(runtime):
    runtime["ctx"].scratch.pop("respawn_session", None)
    r = runtime["registry"].run("session.respawn", runtime["ctx"])
    assert r.ok and runtime["ctx"].scratch.get("respawn_session") is True


# ---------------------------------------------------------------------------
# Items / cache
# ---------------------------------------------------------------------------


def test_items_list_returns_known_source(runtime):
    r = runtime["registry"].run("items.list wishes_source", runtime["ctx"])
    assert r.ok and len(r.data) >= 5


def test_items_show_returns_one(runtime):
    items = runtime["registry"].run("items.list wishes_source", runtime["ctx"]).data
    target = items[0]["id"]
    r = runtime["registry"].run(f"items.show wishes_source {target}", runtime["ctx"])
    assert r.ok and r.data["id"] == target


def test_items_show_missing_errors(runtime):
    r = runtime["registry"].run("items.show wishes_source no:such:item", runtime["ctx"])
    assert not r.ok


def test_items_list_unknown_source_empty(runtime):
    r = runtime["registry"].run("items.list no_such_source", runtime["ctx"])
    assert r.ok and r.data == []


# ---------------------------------------------------------------------------
# Chat
# ---------------------------------------------------------------------------


def test_chat_send_writes_inbox_and_session(runtime):
    r = runtime["registry"].run('chat.send "hello from the test"', runtime["ctx"])
    assert r.ok and "sent" in r.message
    sent_to_session = runtime["sm"].sent
    assert sent_to_session and sent_to_session[-1][1] == "hello from the test"
    msgs = runtime["inbox"].list_all()
    assert msgs and msgs[-1].body == "hello from the test"


def test_chat_send_without_session(runtime):
    runtime["ctx"].active_session_id = None
    r = runtime["registry"].run('chat.send "no session test"', runtime["ctx"])
    # Inbox still works; session.send is skipped.
    assert r.ok and not runtime["sm"].sent


def test_chat_list_after_send(runtime):
    runtime["registry"].run('chat.send "first message"', runtime["ctx"])
    r = runtime["registry"].run("chat.list", runtime["ctx"])
    assert r.ok and "first message" in r.message


# ---------------------------------------------------------------------------
# CLI bridge — the file-queue injection contract
# ---------------------------------------------------------------------------


def test_bridge_drain_executes_queued_commands(runtime):
    state_dir = runtime["cfg"].state_dir
    enqueue(state_dir, "ping cli-injected")
    enqueue(state_dir, 'idea-queue.add "via the bridge"')
    result = drain(state_dir, runtime["registry"], runtime["ctx"])
    assert len(result.commands) == 2
    assert all(r.ok for r in result.results)
    # Queue file is now empty.
    qp = queue_path(state_dir)
    assert qp.exists() and qp.read_text() == ""
    # Idea queue picked up the new item.
    listed = runtime["registry"].run("idea-queue.list", runtime["ctx"])
    assert "via the bridge" in listed.data


def test_bridge_drain_skips_comments_and_blanks(runtime):
    state_dir = runtime["cfg"].state_dir
    queue_path(state_dir).write_text(
        "# this is a comment\n\n   \nping after-blanks\n",
        encoding="utf-8",
    )
    result = drain(state_dir, runtime["registry"], runtime["ctx"])
    assert len(result.commands) == 1 and result.commands[0] == "ping after-blanks"


def test_bridge_drain_respects_max_per_tick(runtime):
    state_dir = runtime["cfg"].state_dir
    for i in range(10):
        enqueue(state_dir, f"ping {i}")
    result = drain(state_dir, runtime["registry"], runtime["ctx"], max_per_tick=3)
    assert len(result.commands) == 3
    # 7 remain in the queue.
    remaining = queue_path(state_dir).read_text().strip().splitlines()
    assert len(remaining) == 7


def test_bridge_logs_show_cli_source(runtime):
    enqueue(runtime["cfg"].state_dir, "ping marker")
    drain(runtime["cfg"].state_dir, runtime["registry"], runtime["ctx"])
    entries = runtime["registry"].log()
    last = entries[-1]
    assert last.source == "cli" and last.command == "ping marker"


# ---------------------------------------------------------------------------
# Source-tagging — gui vs terminal vs cli
# ---------------------------------------------------------------------------


def test_run_gui_logs_with_gui_source(runtime):
    runtime["registry"].run_gui("ping", runtime["ctx"], "from-gui")
    entries = runtime["registry"].log()
    last = entries[-1]
    assert last.source == "gui" and "from-gui" in last.command


def test_run_default_logs_with_terminal_source(runtime):
    runtime["registry"].run("ping from-typing", runtime["ctx"])
    entries = runtime["registry"].log()
    last = entries[-1]
    assert last.source == "terminal"
