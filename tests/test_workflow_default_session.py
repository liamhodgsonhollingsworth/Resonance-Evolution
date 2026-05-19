"""
Tests for the always-on workflow-management default session
(SPEC-002 / SPEC-003 partial — the chat-default + auto-spawn-and-persist).

Uses the same fake-claude fixture as the other end-to-end tests so real
`claude` is not required.
"""

from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path

import pytest

from engine.core import Engine

from tools.workflow.inbox import Inbox
from tools.workflow.session_manager import SessionManager
from tools.workflow.shell import Shell, _build_workflow_mgmt_seed, _detect_alethea_root


HERE = Path(__file__).resolve().parent
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"
REPO_ROOT = HERE.parent


def _make_launcher(tmp_path: Path) -> str:
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


def _wait_until(predicate, timeout_s: float = 3.0):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


@pytest.fixture
def scratch_repo(tmp_path: Path):
    dst = tmp_path / "apeiron_copy"
    dst.mkdir()
    for sub in ("engine", "node_types", "renderers", "scenes"):
        shutil.copytree(REPO_ROOT / sub, dst / sub)
    return dst


def test_seed_includes_skill_and_doc_paths(tmp_path: Path):
    """The seed prompt references the design-specification skill and SPECIFICATIONS doc."""
    apeiron = tmp_path / "apeiron"
    apeiron.mkdir()
    alethea = tmp_path / "alethea"
    alethea.mkdir()
    seed = _build_workflow_mgmt_seed(apeiron, alethea)
    # Contains references to the load-bearing documents.
    assert "specifications/README.md" in seed
    assert "skills/design-specification.md" in seed
    assert "session_types/workflow_management.md" in seed
    assert "mistakes/global.md" in seed
    # Names the absolute paths.
    assert apeiron.as_posix() in seed
    assert alethea.as_posix() in seed
    # Documents the intake responsibility.
    assert "feature description" in seed
    assert "SPEC-NNN" in seed


def test_seed_handles_missing_alethea(tmp_path: Path):
    """When Alethea root isn't found, the seed names the gap rather than crashing."""
    apeiron = tmp_path / "apeiron"
    apeiron.mkdir()
    seed = _build_workflow_mgmt_seed(apeiron, None)
    assert "not detected" in seed.lower() or "ask the maintainer" in seed.lower()


def test_detect_alethea_via_env(tmp_path: Path, monkeypatch):
    """ALETHEA_ROOT env var wins when set."""
    fake_alethea = tmp_path / "explicit_alethea"
    fake_alethea.mkdir()
    monkeypatch.setenv("ALETHEA_ROOT", str(fake_alethea))
    result = _detect_alethea_root(tmp_path / "no_apeiron")
    assert result == fake_alethea


def test_ensure_default_session_spawns_when_no_marker(scratch_repo: Path, tmp_path: Path):
    """First call spawns a new workflow-management session and persists the ID."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    state_dir = tmp_path / "state"
    inbox = Inbox(state_dir=state_dir, alethea_cc_root=None)
    sm = SessionManager(state_dir=state_dir, claude_bin=_make_launcher(tmp_path))

    shell = Shell(
        engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
        alethea_root=None,
    )

    marker = shell._default_session_marker_path()
    assert not marker.exists()
    sid = shell.ensure_default_workflow_mgmt_session()
    assert sid is not None
    assert shell.active_session_id == sid
    assert marker.exists()
    assert marker.read_text().strip() == sid

    sm.shutdown()


def test_ensure_default_session_reuses_existing_marker(scratch_repo: Path, tmp_path: Path):
    """Second call (with marker present + record still on disk) does not spawn a new session."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    state_dir = tmp_path / "state"
    inbox = Inbox(state_dir=state_dir, alethea_cc_root=None)
    sm = SessionManager(state_dir=state_dir, claude_bin=_make_launcher(tmp_path))

    shell = Shell(
        engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
        alethea_root=None,
    )

    sid1 = shell.ensure_default_workflow_mgmt_session()
    assert sid1 is not None
    assert _wait_until(lambda: any(ev.kind == "spawned" for ev in sm.event_queue.queue), 3.0)

    # Reset active_session_id to simulate a fresh shell instance.
    shell.active_session_id = None

    sid2 = shell.ensure_default_workflow_mgmt_session()
    assert sid2 == sid1, "Second call should resume the persisted session, not spawn a new one"
    assert shell.active_session_id == sid1

    sm.shutdown()


def test_ensure_default_session_respawns_when_archived(scratch_repo: Path, tmp_path: Path):
    """If the marker exists but the recorded session is archived, spawn fresh."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    state_dir = tmp_path / "state"
    inbox = Inbox(state_dir=state_dir, alethea_cc_root=None)
    sm = SessionManager(state_dir=state_dir, claude_bin=_make_launcher(tmp_path))

    shell = Shell(
        engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
        alethea_root=None,
    )

    sid1 = shell.ensure_default_workflow_mgmt_session()
    assert _wait_until(lambda: any(ev.kind == "spawned" for ev in sm.event_queue.queue), 3.0)
    sm.archive(sid1)
    assert _wait_until(lambda: sm.get(sid1) is None or sm.get(sid1).status == "archived", 3.0)

    sid2 = shell.ensure_default_workflow_mgmt_session()
    assert sid2 != sid1, "Archived session should be replaced, not reused"

    sm.shutdown()


def test_default_session_failure_leaves_shell_usable(scratch_repo: Path, tmp_path: Path):
    """If claude binary is missing, ensure_default_workflow_mgmt_session returns None gracefully."""
    engine = Engine(root_dir=scratch_repo)
    engine.discover()

    state_dir = tmp_path / "state"
    inbox = Inbox(state_dir=state_dir, alethea_cc_root=None)
    sm = SessionManager(state_dir=state_dir, claude_bin="/no/such/claude/binary")

    shell = Shell(
        engine=engine, session_manager=sm, inbox=inbox, root=scratch_repo,
        alethea_root=None,
    )

    sid = shell.ensure_default_workflow_mgmt_session()
    assert sid is None
    assert shell.active_session_id is None  # nothing set

    sm.shutdown()
