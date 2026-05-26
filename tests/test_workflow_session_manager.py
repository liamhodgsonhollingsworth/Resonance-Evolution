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


def test_send_hydrates_on_cache_miss(tmp_path, monkeypatch):
    """SPEC-068 regression: a SessionManager constructed AFTER another
    process spawned a session must be able to send to that session via
    on-demand hydration from the persisted JSON file.

    The website's terminal_bridge constructs a new SessionManager per
    request. Before this fix, ``send()`` raised ``SessionError('Unknown
    session: ...')`` because the in-memory ``_sessions`` dict was empty;
    only ``list()`` and ``reactivate()`` called ``_hydrate``. The fix
    triggers hydration on cache-miss inside ``send()`` so the spawn-
    in-process-A / send-from-process-B flow that SPEC-068 requires
    works through the website surface.

    Test approach: spawn via SessionManager-A, write the JSON to disk,
    construct SessionManager-B against the same state_dir, then send.
    Pre-fix: SessionError; post-fix: succeeds (reactivates from disk).
    """
    sm_a = _make_sm(tmp_path, monkeypatch)
    rec = sm_a.spawn(session_type="test", display_name="cross-proc")
    _wait_for_events(sm_a, {"spawned"}, timeout_s=3.0)
    # Confirm record is persisted on disk.
    on_disk = sm_a.sessions_dir / f"{rec.id}.json"
    assert on_disk.exists()
    sm_a.shutdown()

    # Fresh SessionManager-B against the same state_dir (e.g. a website
    # request-handler creating a per-request manager).
    launcher = tmp_path / "fake_claude_launcher.bat"
    if os.name == "nt":
        claude_bin = str(launcher)
    else:
        launcher = tmp_path / "fake_claude_launcher.sh"
        claude_bin = str(launcher)
    sm_b = SessionManager(state_dir=tmp_path / "state", claude_bin=claude_bin)
    # Pre-condition: sm_b's in-memory dict is empty.
    assert sm_b._sessions == {}
    # Send should hydrate, find the on-disk record, then attempt reactivation.
    # Reactivation may relaunch the subprocess; we accept either silent
    # success or BrokenPipeError (the previous child terminated on
    # sm_a.shutdown). The test asserts the function does NOT raise
    # SessionError('Unknown session: ...') — that's the bug we fixed.
    try:
        sm_b.send(rec.id, "post-fix should hydrate from disk")
    except SessionError as exc:
        assert "Unknown session" not in str(exc), (
            f"hydrate-on-cache-miss broken: send still raised Unknown session: {exc}"
        )
    sm_b.shutdown()
