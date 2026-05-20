"""
Tests for tools.workflow.session_manager.

Drives the SessionManager against a fake-claude script that emits a
controllable stream-json conversation. Avoids any real `claude` CLI
dependency.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import List

import pytest

from tools.workflow.session_manager import (
    SessionEvent,
    SessionError,
    SessionManager,
)


HERE = Path(__file__).resolve().parent
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"


def _fake_claude_cmd() -> str:
    """Resolve a command that invokes the fake-claude script via the current Python."""
    return f"{sys.executable} {FAKE_CLAUDE}"


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _wait_for_events(sm: SessionManager, kinds, timeout_s: float = 5.0) -> List[SessionEvent]:
    """
    Drain events until at least one of each `kind` in `kinds` has been seen
    (or timeout). Returns the full list of events drained.
    """
    target = set(kinds)
    out: List[SessionEvent] = []
    seen: set = set()
    deadline = time.time() + timeout_s
    while time.time() < deadline and not target.issubset(seen):
        new = sm.drain_events()
        for ev in new:
            out.append(ev)
            seen.add(ev.kind)
        if not new:
            time.sleep(0.05)
    return out


def _make_sm(tmp_path: Path, monkeypatch) -> SessionManager:
    """Construct a SessionManager that uses the fake-claude python script."""
    # Use a wrapper executable: passing the python interpreter and the script
    # as separate args to Popen via list mode. SessionManager builds the full
    # argv from `self.claude_bin` + flags, so we set `claude_bin` to a
    # shell-friendly string that the subprocess module handles when
    # `shell=False` and args is a list. We can't put two-token claude_bin
    # directly, so instead we wrap by giving the env a script path and a
    # tiny launcher.
    launcher = tmp_path / "fake_claude_launcher.bat"
    if os.name == "nt":
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{FAKE_CLAUDE}" %*\r\n'
        )
        claude_bin = str(launcher)
    else:
        launcher = tmp_path / "fake_claude_launcher.sh"
        launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_CLAUDE}" "$@"\n')
        launcher.chmod(0o755)
        claude_bin = str(launcher)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=claude_bin)
    return sm


def test_spawn_emits_spawned_event(tmp_path, monkeypatch):
    sm = _make_sm(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="t1")
    events = _wait_for_events(sm, {"spawned"}, timeout_s=3.0)
    assert any(ev.kind == "spawned" and ev.session_id == rec.id for ev in events)
    sm.shutdown()


def test_send_receives_assistant_text(tmp_path, monkeypatch):
    sm = _make_sm(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="t1")
    _wait_for_events(sm, {"spawned"}, timeout_s=3.0)
    sm.send(rec.id, "hello fake-claude")
    events = _wait_for_events(sm, {"communication", "turn_complete"}, timeout_s=5.0)
    comm = [e for e in events if e.kind == "communication"]
    assert any("echo:" in (e.payload.get("text") or "") for e in comm)
    sm.shutdown()


def test_unknown_event_is_activity(tmp_path, monkeypatch):
    sm = _make_sm(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="t1")
    _wait_for_events(sm, {"spawned"}, timeout_s=3.0)
    sm.send(rec.id, "trigger-unknown-event")
    events = _wait_for_events(sm, {"activity"}, timeout_s=5.0)
    assert any(
        ev.kind == "activity" and "unknown_event_type" in ev.payload
        for ev in events
    )
    sm.shutdown()


def test_session_record_persisted_on_disk(tmp_path, monkeypatch):
    sm = _make_sm(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="t1")
    _wait_for_events(sm, {"spawned"}, timeout_s=3.0)
    path = sm.sessions_dir / f"{rec.id}.json"
    assert path.exists()
    data = json.loads(path.read_text())
    assert data["display_name"] == "t1"
    sm.shutdown()


def test_archive_terminates_and_moves_record(tmp_path, monkeypatch):
    sm = _make_sm(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="archive-me")
    _wait_for_events(sm, {"spawned"}, timeout_s=3.0)
    sm.archive(rec.id)
    archived_path = sm.archive_dir / f"session_{rec.id}.json"
    assert _wait_until(lambda: archived_path.exists(), timeout_s=3.0)
    sm.shutdown()


def test_spawn_strips_billing_mode_env_vars(tmp_path, monkeypatch):
    """The spawned ``claude`` subprocess must NOT inherit billing-mode
    env vars from the parent process. If ANTHROPIC_API_KEY is set in the
    maintainer's user environment, the spawned session would use API
    billing (charged per call) instead of the Claude Code plan (covered
    by their subscription). The session manager strips these vars from
    the subprocess env explicitly.
    """
    import subprocess as _subprocess

    sm = _make_sm(tmp_path, monkeypatch)

    # Inject the variables we expect to be stripped.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-should-be-stripped")
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "token-should-be-stripped")
    monkeypatch.setenv("CLAUDE_CODE_USE_BEDROCK", "1")
    monkeypatch.setenv("CLAUDE_CODE_USE_VERTEX", "1")
    monkeypatch.setenv("ANTHROPIC_BASE_URL", "https://corporate-proxy.example/")

    captured_env = {}
    original_popen = _subprocess.Popen

    def _capture_popen(*args, **kwargs):
        captured_env.update(kwargs.get("env") or {})
        return original_popen(*args, **kwargs)

    monkeypatch.setattr(_subprocess, "Popen", _capture_popen)

    rec = sm.spawn(session_type="test", display_name="env-check")
    _wait_for_events(sm, {"spawned"}, timeout_s=3.0)

    # Billing-mode variables must be absent from the subprocess env.
    assert "ANTHROPIC_API_KEY" not in captured_env, (
        "ANTHROPIC_API_KEY leaked into spawned subprocess env — would force API billing"
    )
    assert "ANTHROPIC_AUTH_TOKEN" not in captured_env
    assert "CLAUDE_CODE_USE_BEDROCK" not in captured_env
    assert "CLAUDE_CODE_USE_VERTEX" not in captured_env

    # ANTHROPIC_BASE_URL is preserved — it only takes effect when one of
    # the billing-mode vars above is set, so its presence under OAuth
    # mode is harmless and the maintainer may have set it deliberately.
    assert captured_env.get("ANTHROPIC_BASE_URL") == "https://corporate-proxy.example/"

    # Non-billing PATH/PYTHONPATH inheritance still works.
    assert "PATH" in captured_env

    sm.shutdown()


def test_missing_claude_binary_raises(tmp_path):
    sm = SessionManager(state_dir=tmp_path, claude_bin="/no/such/claude/binary")
    with pytest.raises(SessionError):
        sm.spawn(session_type="test", display_name="should-fail")
    sm.shutdown()
