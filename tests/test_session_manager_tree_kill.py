"""
Regression test for SessionManager Windows subprocess-tree termination.

Background: ``SessionManager.archive`` used to call ``s.child.terminate()``,
which on Windows only signals the ``cmd.exe`` wrapper that invokes
``claude.cmd``. The actual ``claude`` process (and anything ``claude``
itself spawned) was orphaned, held file handles, and kept writing to
log files the archive flow expected to be quiescent. This is
deferred-concerns entry #21 (HIGH severity) — fixed by
``tools.workflow.session_manager._kill_child_tree``.

This file verifies the fix end-to-end on Windows:
- Spawn a SessionManager-managed fake-claude (via .bat launcher, so
  the chain mirrors production: cmd.exe -> fake_claude.py).
- fake_claude.py is asked (via env var) to spawn its OWN long-lived
  grandchild and publish the grandchild's PID to a file.
- The test reads the grandchild PID, archives the session, and asserts
  the grandchild PID is no longer alive in tasklist.

On non-Windows platforms the platform-specific behavior is skipped
(POSIX ``terminate()`` propagation is the OS's job and is already
covered by the existing archive test in test_workflow_session_manager.py).

Also covers ``_kill_child_tree`` directly with two unit-flavor tests
that don't depend on the SessionManager plumbing.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from tools.workflow.session_manager import SessionManager, _kill_child_tree


HERE = Path(__file__).resolve().parent
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _pid_alive(pid: int) -> bool:
    """Return True iff a process with this PID exists on the platform."""
    if sys.platform == "win32":
        try:
            res = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH", "/FO", "CSV"],
                capture_output=True, text=True, timeout=5.0,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return False
        # tasklist prints a header-only ("No tasks running") line when
        # nothing matches; PID-as-string presence is the cleanest probe.
        return str(pid) in res.stdout
    else:
        try:
            os.kill(pid, 0)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False


def _make_sm_with_grandchild(tmp_path: Path, monkeypatch) -> tuple[SessionManager, Path]:
    """Construct a SessionManager whose fake-claude spawns a grandchild.

    Returns (sm, grandchild_pid_file). The caller is responsible for
    reading the file once the spawn settles and for calling
    sm.shutdown() (which itself goes through _kill_child_tree).
    """
    grandchild_pid_file = tmp_path / "grandchild_pid.txt"
    monkeypatch.setenv("FAKE_CLAUDE_GRANDCHILD_PID_FILE", str(grandchild_pid_file))

    launcher = tmp_path / "fake_claude_launcher.bat"
    if os.name == "nt":
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{FAKE_CLAUDE}" %*\r\n'
        )
        claude_bin = str(launcher)
    else:
        launcher = tmp_path / "fake_claude_launcher.sh"
        launcher.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_CLAUDE}" "$@"\n'
        )
        launcher.chmod(0o755)
        claude_bin = str(launcher)
    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=claude_bin)
    return sm, grandchild_pid_file


# ---------------------------------------------------------------------------
# The headline regression test — runs only on Windows where the bug exists.
# ---------------------------------------------------------------------------


@pytest.mark.skipif(
    sys.platform != "win32",
    reason="deferred-concerns #21 is Windows-specific: cmd.exe wraps claude.cmd",
)
def test_archive_kills_grandchild_on_windows(tmp_path, monkeypatch):
    """SessionManager.archive must kill the entire subprocess tree on Windows.

    The fake-claude spawns a long-lived grandchild and publishes its PID.
    After archive(), tasklist must show the grandchild PID is gone — if
    only the cmd.exe wrapper is killed (the pre-fix behavior), the
    grandchild remains alive and this assertion fails.
    """
    sm, pid_file = _make_sm_with_grandchild(tmp_path, monkeypatch)
    try:
        rec = sm.spawn(session_type="test", display_name="tree-kill-target")
        # Wait for fake_claude to publish the grandchild PID.
        assert _wait_until(lambda: pid_file.exists(), timeout_s=10.0), (
            "fake_claude never published a grandchild PID — spawn likely failed"
        )
        # Re-read defensively: tiny race between exists() returning True
        # and the rename completing. The .replace() in fake_claude is
        # atomic but we still want to handle a stray empty read.
        grandchild_pid_str = ""
        assert _wait_until(
            lambda: (pid_file.read_text(encoding="utf-8").strip() or "").isdigit(),
            timeout_s=5.0,
        ), "grandchild PID file present but did not contain a PID"
        grandchild_pid = int(pid_file.read_text(encoding="utf-8").strip())
        assert _pid_alive(grandchild_pid), (
            f"grandchild PID {grandchild_pid} reported by fake_claude is "
            "not alive in tasklist — test scaffolding broken"
        )

        # The act under test.
        sm.archive(rec.id)

        # The fix's contract: by the time archive() returns + the OS
        # finishes reaping, the grandchild is gone. Give it a short
        # window because Windows process-exit isn't instantaneous.
        assert _wait_until(
            lambda: not _pid_alive(grandchild_pid), timeout_s=5.0
        ), (
            f"grandchild PID {grandchild_pid} still alive after archive — "
            "the cmd.exe wrapper was killed but the descendant tree wasn't "
            "(deferred-concerns entry #21 regression)"
        )
    finally:
        sm.shutdown()


@pytest.mark.skipif(
    sys.platform != "win32",
    reason="shutdown's tree-kill path is Windows-specific",
)
def test_shutdown_kills_grandchild_on_windows(tmp_path, monkeypatch):
    """SessionManager.shutdown must also walk the tree on Windows.

    archive() and shutdown() both call _kill_child_tree; this guards the
    shutdown path independently in case future refactors split the call
    sites or change one without the other.
    """
    sm, pid_file = _make_sm_with_grandchild(tmp_path, monkeypatch)
    rec = sm.spawn(session_type="test", display_name="shutdown-tree-kill")
    assert _wait_until(lambda: pid_file.exists(), timeout_s=10.0)
    assert _wait_until(
        lambda: (pid_file.read_text(encoding="utf-8").strip() or "").isdigit(),
        timeout_s=5.0,
    )
    grandchild_pid = int(pid_file.read_text(encoding="utf-8").strip())
    assert _pid_alive(grandchild_pid)

    sm.shutdown()

    assert _wait_until(
        lambda: not _pid_alive(grandchild_pid), timeout_s=5.0
    ), (
        f"grandchild PID {grandchild_pid} still alive after shutdown — "
        "shutdown's kill path did not walk the tree"
    )


# ---------------------------------------------------------------------------
# Direct unit-flavor tests for _kill_child_tree. Cross-platform.
# ---------------------------------------------------------------------------


def test_kill_child_tree_no_op_on_already_dead_child():
    """_kill_child_tree on an already-exited child must not raise."""
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait(timeout=5)
    assert child.poll() is not None  # confirms it's dead
    # Must not raise.
    _kill_child_tree(child)


def test_kill_child_tree_kills_live_child():
    """_kill_child_tree on a live child must terminate it within the timeout."""
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
    )
    try:
        # Sanity: child is alive.
        assert child.poll() is None
        _kill_child_tree(child)
        # After the call, the OS may take a moment; give it a short window.
        assert _wait_until(lambda: child.poll() is not None, timeout_s=5.0), (
            "_kill_child_tree returned but the child is still alive"
        )
    finally:
        # Belt + suspenders: make sure we don't leak a child if the
        # assertion above ever fires.
        if child.poll() is None:
            try:
                child.kill()
                child.wait(timeout=5)
            except Exception:
                pass
