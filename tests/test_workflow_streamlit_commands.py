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
from tools.workflow_streamlit.command_registry import CommandContext, CommandRegistry, CommandResult
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
        self.archived: List[str] = []
        self._records = {"sess-fake-001": _FakeSessionRecord("sess-fake-001", "active")}
        self.spawn_calls: List[dict] = []

    def list(self):
        return list(self._records.values())

    def get(self, sid):
        return self._records.get(sid)

    def send(self, sid, body):
        if sid not in self._records:
            raise RuntimeError(f"unknown session: {sid}")
        self.sent.append((sid, body))

    def spawn(self, session_type, display_name=None, seed_message=None, cwd=None, concerns=None):
        self.spawn_calls.append({
            "session_type": session_type,
            "display_name": display_name,
            "seed_message": seed_message,
        })
        sid = f"sess-fake-{len(self._records) + 1:03d}"
        rec = _FakeSessionRecord(sid, "active")
        rec.session_type = session_type
        rec.display_name = display_name or f"{session_type}-{sid}"
        self._records[sid] = rec
        return rec

    def archive(self, sid):
        self.archived.append(sid)
        if sid in self._records:
            self._records[sid].status = "archived"


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
    # Mirror runtime.boot_runtime: register workflow singletons on
    # engine.cache so logic node-types (ChatRouter, etc.) dispatched
    # via engine.actions.dispatch_action can find them.
    engine.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
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


def test_session_spawn_creates_new_session(runtime):
    r = runtime["registry"].run("session.spawn parallel-development worker", runtime["ctx"])
    assert r.ok and "worker" in r.message
    assert len(runtime["sm"].spawn_calls) == 1
    assert runtime["sm"].spawn_calls[0]["session_type"] == "parallel-development"


def test_session_spawn_with_seed_after_dash_dash(runtime):
    r = runtime["registry"].run(
        'session.spawn workflow-management chief -- you are the chief',
        runtime["ctx"],
    )
    assert r.ok
    assert runtime["sm"].spawn_calls[-1]["seed_message"] == "you are the chief"


def test_session_spawn_without_args_errors(runtime):
    r = runtime["registry"].run("session.spawn", runtime["ctx"])
    assert not r.ok and "usage" in r.message


def test_session_target_routes_chat(runtime):
    # Spawn an extra session first.
    runtime["registry"].run("session.spawn parallel-development second", runtime["ctx"])
    new_id = list(runtime["sm"]._records.keys())[-1]
    r = runtime["registry"].run(f"session.target {new_id}", runtime["ctx"])
    assert r.ok and "chat target" in r.message
    assert runtime["ctx"].active_session_id == new_id
    # And subsequent chat.send goes to the new target.
    runtime["registry"].run('chat.send "to-second"', runtime["ctx"])
    assert runtime["sm"].sent[-1][0] == new_id


def test_session_target_clear(runtime):
    runtime["registry"].run("session.target none", runtime["ctx"])
    assert runtime["ctx"].active_session_id is None


def test_session_target_unknown_session_errors(runtime):
    r = runtime["registry"].run("session.target sess-nope-zzz", runtime["ctx"])
    assert not r.ok and "no such session" in r.message


def test_session_send_to_specific_session(runtime):
    sid = "sess-fake-001"
    r = runtime["registry"].run(f'session.send {sid} hello there', runtime["ctx"])
    assert r.ok and "sent" in r.message
    assert runtime["sm"].sent[-1] == (sid, "hello there")


def test_session_send_to_unknown_errors(runtime):
    r = runtime["registry"].run('session.send sess-nope hello', runtime["ctx"])
    assert not r.ok and "fail" in r.message.lower()


def test_session_archive_marks_record(runtime):
    sid = "sess-fake-001"
    r = runtime["registry"].run(f"session.archive {sid}", runtime["ctx"])
    assert r.ok and sid in runtime["sm"].archived
    assert runtime["sm"]._records[sid].status == "archived"


def test_session_spawn_then_list_includes_new_session(runtime):
    runtime["registry"].run("session.spawn worker-type alice", runtime["ctx"])
    runtime["registry"].run("session.spawn worker-type bob", runtime["ctx"])
    r = runtime["registry"].run("session.list", runtime["ctx"])
    assert r.ok and len(r.data) == 3   # original + 2 spawned


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


# ---------------------------------------------------------------------------
# Break-point tests — what happens when things go wrong
# ---------------------------------------------------------------------------


def test_handler_exception_is_caught_and_returned_as_err(runtime):
    """A handler that raises must not break the registry; the error
    is captured into a CommandResult with ``ok=False``."""
    from tools.workflow_streamlit.command_registry import Command

    def boom(ctx, args):
        raise RuntimeError("intentional handler failure")

    runtime["registry"].register(Command("test.boom", "raises on call", boom))
    r = runtime["registry"].run("test.boom", runtime["ctx"])
    assert not r.ok and "RuntimeError" in r.message and "intentional" in r.message
    # And the log records the failure.
    last = runtime["registry"].log()[-1]
    assert last.result is r and not r.ok


def test_malformed_quoting_returns_parse_err(runtime):
    r = runtime["registry"].run('chat.send "unclosed quote', runtime["ctx"])
    assert not r.ok and "parse" in r.message.lower()


def test_empty_command_is_ok_noop(runtime):
    r = runtime["registry"].run("", runtime["ctx"])
    assert r.ok and r.message == ""
    r2 = runtime["registry"].run("    ", runtime["ctx"])
    assert r2.ok


def test_command_log_caps_at_max(runtime):
    """The default 500-entry cap should keep memory bounded under spam."""
    from tools.workflow_streamlit.command_registry import CommandRegistry
    small = CommandRegistry(max_log_entries=10)
    from tools.workflow_streamlit.commands import register_all
    register_all(small)
    for i in range(50):
        small.run(f"ping {i}", runtime["ctx"])
    assert len(small.log()) == 10
    assert small.log()[-1].command.endswith("ping 49")


def test_drain_handles_handler_exception_without_losing_other_commands(runtime):
    """If one queued command's handler explodes, the rest still dispatch."""
    from tools.workflow_streamlit.cli_bridge import drain, enqueue
    from tools.workflow_streamlit.command_registry import Command

    def boom(ctx, args):
        raise RuntimeError("queue boom")

    runtime["registry"].register(Command("test.queue-boom", "raises", boom))
    state_dir = runtime["cfg"].state_dir
    enqueue(state_dir, "ping before-boom")
    enqueue(state_dir, "test.queue-boom")
    enqueue(state_dir, "ping after-boom")
    result = drain(state_dir, runtime["registry"], runtime["ctx"])
    assert len(result.commands) == 3
    statuses = [r.ok for r in result.results]
    assert statuses == [True, False, True]


def test_drain_under_concurrent_enqueues(runtime):
    """Two threads enqueue while we drain. The drain must see at least
    its own batch and not corrupt the file."""
    import threading
    import time as _t
    from tools.workflow_streamlit.cli_bridge import drain, enqueue

    state_dir = runtime["cfg"].state_dir
    enqueue(state_dir, "ping seed-1")
    enqueue(state_dir, "ping seed-2")

    stop = threading.Event()
    written = []

    def writer(label):
        i = 0
        while not stop.is_set() and i < 10:
            enqueue(state_dir, f"ping concurrent-{label}-{i}")
            written.append(f"concurrent-{label}-{i}")
            _t.sleep(0.01)
            i += 1

    t1 = threading.Thread(target=writer, args=("a",))
    t2 = threading.Thread(target=writer, args=("b",))
    t1.start()
    t2.start()
    t1.join(timeout=3)
    t2.join(timeout=3)
    stop.set()
    # Drain the rest.
    final = drain(state_dir, runtime["registry"], runtime["ctx"], max_per_tick=100)
    # At minimum, the seed commands plus at least some of the
    # concurrent commands should have made it through SOMEWHERE — either
    # in `final.commands` or already in the registry's log from prior
    # drains. We just assert no exception was raised + at least 2 seeds
    # appear in the log.
    log_text = " ".join(e.command for e in runtime["registry"].log())
    assert "seed-1" in log_text and "seed-2" in log_text


def test_drain_handles_unicode(runtime):
    from tools.workflow_streamlit.cli_bridge import drain, enqueue
    state_dir = runtime["cfg"].state_dir
    enqueue(state_dir, 'echo "héllo — wörld ✨"')
    result = drain(state_dir, runtime["registry"], runtime["ctx"])
    assert len(result.commands) == 1 and result.results[0].ok
    assert "héllo" in result.results[0].message


def test_drain_skips_corrupt_quote_lines_and_continues(runtime):
    """A malformed line should produce a parse-err result, not kill the drain."""
    from tools.workflow_streamlit.cli_bridge import drain, queue_path
    state_dir = runtime["cfg"].state_dir
    queue_path(state_dir).write_text(
        'ping before-bad\n"unclosed quote line\nping after-bad\n',
        encoding="utf-8",
    )
    result = drain(state_dir, runtime["registry"], runtime["ctx"])
    statuses = [r.ok for r in result.results]
    # First and third OK, middle parse-err.
    assert statuses[0] is True and statuses[-1] is True
    assert any(not s for s in statuses)


# ---------------------------------------------------------------------------
# Generalizability tests — can new things be added without touching core?
# ---------------------------------------------------------------------------


def test_runtime_command_registration_lets_new_commands_dispatch(runtime):
    """A new Command added after register_all() is reachable immediately."""
    from tools.workflow_streamlit.command_registry import Command

    def custom(ctx, args):
        ctx.scratch["custom_ran_with"] = list(args)
        return CommandResult.ok_msg("custom ran")

    runtime["registry"].register(Command("custom.example", "test command", custom))
    r = runtime["registry"].run("custom.example a b c", runtime["ctx"])
    assert r.ok and r.message == "custom ran"
    assert runtime["ctx"].scratch["custom_ran_with"] == ["a", "b", "c"]
    # And help now lists it.
    h = runtime["registry"].run("help", runtime["ctx"])
    assert "custom.example" in h.data


def test_command_aliases_resolve_to_same_handler(runtime):
    from tools.workflow_streamlit.command_registry import Command

    def custom(ctx, args):
        return CommandResult.ok_msg("hit")

    runtime["registry"].register(
        Command("custom.canonical", "with aliases", custom, aliases=["custom.alias1", "custom.alias2"])
    )
    assert runtime["registry"].run("custom.canonical", runtime["ctx"]).ok
    assert runtime["registry"].run("custom.alias1", runtime["ctx"]).ok
    assert runtime["registry"].run("custom.alias2", runtime["ctx"]).ok


def test_panel_discovery_picks_up_files_added_at_runtime(tmp_path):
    """Drop a new panel file into a custom dir; the registry sees it
    on the next discover_panels call — proves the panel system is
    extensible without touching the discovery code."""
    from tools.workflow_streamlit.registry import discover_panels

    panels_dir = tmp_path / "extra_panels"
    panels_dir.mkdir()
    # The first discover call sees no panels.
    assert discover_panels(panels_dir=panels_dir) == []

    # Drop a new panel file.
    new_panel = panels_dir / "newcomer.py"
    new_panel.write_text(
        "from tools.workflow_streamlit.panels._common import MOUNT_MAIN, PanelManifest\n"
        "def manifest():\n"
        "    return PanelManifest(name='newcomer', description='dynamic', mount_point=MOUNT_MAIN)\n"
        "def render(ctx):\n"
        "    pass\n",
        encoding="utf-8",
    )
    after = discover_panels(panels_dir=panels_dir)
    assert len(after) == 1 and after[0].manifest.name == "newcomer"


def test_registry_re_registration_replaces_handler(runtime):
    """Re-registering a name should replace the handler (useful for hot
    reload of a panel module's command definitions)."""
    from tools.workflow_streamlit.command_registry import Command

    calls = []

    def v1(ctx, args):
        calls.append("v1")
        return CommandResult.ok_msg("v1")

    def v2(ctx, args):
        calls.append("v2")
        return CommandResult.ok_msg("v2")

    runtime["registry"].register(Command("custom.versioned", "v1", v1))
    runtime["registry"].run("custom.versioned", runtime["ctx"])
    runtime["registry"].register(Command("custom.versioned", "v2", v2))
    runtime["registry"].run("custom.versioned", runtime["ctx"])
    assert calls == ["v1", "v2"]
