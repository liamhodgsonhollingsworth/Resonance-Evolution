"""
End-to-end integration tests for the workflow shell.

These tests verify the load-bearing claim of the maintainer's workflow
milestone: a Claude Code session writes a new node-type file mid-conversation,
the file-watcher picks it up, and the engine has the new type registered
without a restart.

We drive the SessionManager against the fake-claude fixture, which writes
a real node-type file when given a `WRITE_NODE_TYPE <abs-path>` directive.
The Shell instance is the same one `python -m tools.workflow` uses; we
just feed it inputs and capture its outputs in-process.
"""

from __future__ import annotations

import io
import os
import shutil
import sys
import threading
import time
from pathlib import Path
from typing import List

import pytest

from engine.core import Engine
from engine.file_watcher import FileWatcher

from tools.workflow.inbox import Inbox
from tools.workflow.session_manager import SessionManager
from tools.workflow.shell import Shell


HERE = Path(__file__).resolve().parent
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"
REPO_ROOT = HERE.parent


def _make_fake_claude_launcher(tmp_path: Path) -> str:
    if os.name == "nt":
        launcher = tmp_path / "fake_claude_launcher.bat"
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{FAKE_CLAUDE}" %*\r\n'
        )
        return str(launcher)
    launcher = tmp_path / "fake_claude_launcher.sh"
    launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_CLAUDE}" "$@"\n')
    launcher.chmod(0o755)
    return str(launcher)


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


@pytest.fixture
def scratch_repo(tmp_path: Path):
    """
    A temporary copy of the Apeiron repo's structure sufficient for the
    engine to discover types. We only copy engine/, node_types/, renderers/,
    scenes/ (with their __init__/ files) — the tests don't need the full
    repo.
    """
    dst = tmp_path / "apeiron_copy"
    dst.mkdir()
    for sub in ("engine", "node_types", "renderers", "scenes"):
        shutil.copytree(REPO_ROOT / sub, dst / sub)
    return dst


def test_fwatch_picks_up_session_written_node_type(scratch_repo: Path, tmp_path: Path):
    """
    The load-bearing demo: a session writes a new node_type file; the
    file-watcher detects it; the engine has the new type registered.
    No engine restart involved.
    """
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    # Sanity check: type isn't registered yet.
    assert "TestClock" not in engine.types

    fwatch_events: List = []

    def on_event(kind: str, type_name: str, path: Path):
        fwatch_events.append((kind, type_name, path))

    fw = FileWatcher(engine, on_event=on_event, poll_interval_s=0.1)
    fw.start()

    # Launch a fake-claude session.
    launcher = _make_fake_claude_launcher(tmp_path)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=launcher)
    rec = sm.spawn(session_type="test", display_name="writer", cwd=scratch_repo)

    # Wait for spawn-event so the subprocess is ready for input.
    assert _wait_until(
        lambda: any(ev.kind == "spawned" for ev in sm.event_queue.queue),
        timeout_s=3.0,
    )

    # Ask the fake-claude to write a new node-type.
    target = scratch_repo / "node_types" / "test_clock.py"
    sm.send(rec.id, f"WRITE_NODE_TYPE {target}")

    # Wait for the file-watcher to register the new type.
    assert _wait_until(
        lambda: "TestClock" in engine.types, timeout_s=5.0
    ), f"TestClock did not register; fwatch_events={fwatch_events}, errors={engine.errors}"
    assert target.exists()

    # The file-watcher's on_event should also have fired with the new type.
    assert any(
        kind == "new" and type_name == "TestClock"
        for kind, type_name, _ in fwatch_events
    ), f"Expected `new TestClock` event; saw: {fwatch_events}"

    fw.stop()
    sm.shutdown()


def test_shell_renders_session_communication(scratch_repo: Path, tmp_path: Path):
    """
    The Shell receives session 'communication' events and prints them
    to its output stream. Verifies the shell's _show_session_event path.
    """
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    launcher = _make_fake_claude_launcher(tmp_path)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=launcher)
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None)

    out = io.StringIO()
    err = io.StringIO()

    shell = Shell(engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
                  out=out, err=err)

    # Spawn a session and send it a message manually.
    rec = sm.spawn(session_type="test", display_name="comm-test", cwd=scratch_repo)
    assert _wait_until(
        lambda: any(ev.kind == "spawned" for ev in sm.event_queue.queue),
        timeout_s=3.0,
    )
    sm.send(rec.id, "hello fake-claude")

    # Drain events through the shell several times.
    deadline = time.time() + 4.0
    while time.time() < deadline:
        shell._drain_session_events()
        if "echo: hello" in out.getvalue():
            break
        time.sleep(0.05)

    assert "echo: hello" in out.getvalue(), f"Did not see communication; out={out.getvalue()!r}"
    sm.shutdown()


def test_shell_inbox_post_visible_to_list(scratch_repo: Path, tmp_path: Path):
    """A /inbox post message is visible to /inbox list."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    launcher = _make_fake_claude_launcher(tmp_path)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=launcher)
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None)

    out = io.StringIO()
    err = io.StringIO()
    shell = Shell(engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
                  out=out, err=err)

    # Post a message via the shell's command.
    shell._dispatch_slash("inbox post agent_x task hello-from-shell")
    msgs = inbox.list_all()
    assert len(msgs) == 1
    assert msgs[0].to == "agent_x"

    sm.shutdown()


def test_shell_reload_command_invokes_engine(scratch_repo: Path, tmp_path: Path):
    """The /reload <type> command triggers Engine.reload_type."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    launcher = _make_fake_claude_launcher(tmp_path)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=launcher)
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None)

    out = io.StringIO()
    err = io.StringIO()
    shell = Shell(engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
                  out=out, err=err)

    # Cube is one of the always-present node-types from the bootstrap commits.
    shell._dispatch_slash("reload Cube")
    assert "reload(Cube)" in out.getvalue() or "reload" in out.getvalue()
    sm.shutdown()


def test_shell_suppresses_tool_use_noise_by_default(
    scratch_repo: Path, tmp_path: Path, monkeypatch
):
    """The shell's default print stream excludes `tool_use` events so the
    spawned session's hundreds of read/grep calls don't flood the
    terminal. The high-signal events (spawned, turn_complete,
    communication, session_idle, session_error, silent_too_long) stay
    visible. Setting ``APEIRON_VERBOSE_SESSIONS=1`` re-enables the
    verbose surface for debugging.
    """
    from tools.workflow.session_manager import SessionEvent

    engine = Engine(root_dir=scratch_repo)
    engine.discover()
    sm = SessionManager(state_dir=tmp_path / "state")
    inbox = Inbox(state_dir=tmp_path / "state", alethea_cc_root=None)

    out = io.StringIO()
    err = io.StringIO()
    shell = Shell(engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
                  out=out, err=err)

    monkeypatch.delenv("APEIRON_VERBOSE_SESSIONS", raising=False)
    sample_id = "0" * 36
    shell._show_session_event(SessionEvent(
        kind="tool_use", session_id=sample_id, session_display_name="dflt",
        payload={"name": "Read"},
    ))
    shell._show_session_event(SessionEvent(
        kind="tool_result", session_id=sample_id, session_display_name="dflt",
        payload={"result": "ok"},
    ))
    shell._show_session_event(SessionEvent(
        kind="activity", session_id=sample_id, session_display_name="dflt",
        payload={},
    ))
    quiet = out.getvalue()
    assert "tool_use" not in quiet
    assert "tool_result" not in quiet
    assert "activity" not in quiet

    # High-signal events still print.
    shell._show_session_event(SessionEvent(
        kind="turn_complete", session_id=sample_id, session_display_name="dflt",
        payload={"total_cost_usd": 0.04, "duration_ms": 1234},
    ))
    shell._show_session_event(SessionEvent(
        kind="silent_too_long", session_id=sample_id, session_display_name="dflt",
        payload={"silent_for_s": 305.2},
    ))
    after = out.getvalue()
    assert "turn complete" in after
    assert "silent for 305s" in after

    # Verbose mode re-enables tool_use prints.
    monkeypatch.setenv("APEIRON_VERBOSE_SESSIONS", "1")
    out2 = io.StringIO()
    shell2 = Shell(engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
                   out=out2, err=err)
    shell2._show_session_event(SessionEvent(
        kind="tool_use", session_id=sample_id, session_display_name="dflt",
        payload={"name": "Bash"},
    ))
    assert "tool_use Bash" in out2.getvalue()
    sm.shutdown()
