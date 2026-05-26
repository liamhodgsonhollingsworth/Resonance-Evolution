"""
Platform-matrix tests for the SessionManager supervisor primitive.

The end-to-end behavior is covered by
``tests/test_streamjson_orphan_cleanup.py`` (supervisor-marked, slow,
spawns real subprocesses). This file pins the per-platform contract
at unit-level so a regression that swaps the platform-branch wiring
without changing observable orphan behavior would still be caught.

Platform contract (see
``tools/workflow/session_manager._install_supervisor``):

- Windows: a process-wide Job Object is created on first spawn (with
  ``JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE``), and every spawned child is
  assigned to it via ``AssignProcessToJobObject``.
- Linux: ``preexec_fn=_set_pdeathsig`` is passed to ``subprocess.Popen``,
  installing ``PR_SET_PDEATHSIG=SIGKILL`` in the child after fork /
  before exec.
- macOS / other POSIX: no primitive available; ``_install_supervisor``
  logs once and returns. The cooperative ``_kill_child_tree`` path
  remains the only line of defence on those platforms.
"""

from __future__ import annotations

import subprocess
import sys
import threading
import time
from pathlib import Path
from unittest import mock

import pytest

from tools.workflow import session_manager
from tools.workflow.session_manager import (
    SessionManager,
    _get_or_create_win_job,
    _install_supervisor,
    _is_linux,
    _is_windows,
    _set_pdeathsig,
)


HERE = Path(__file__).resolve().parent
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"


# ---------------------------------------------------------------------------
# Windows: Job Object is created at first spawn, child assigned to it.
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _is_windows(), reason="Windows-only path")
def test_windows_job_object_is_created_on_demand():
    """The process-wide Job Object handle exists after the first call."""
    job = _get_or_create_win_job()
    assert job is not None, "Job Object creation failed on Windows"
    assert isinstance(job, int) and job != 0


@pytest.mark.skipif(not _is_windows(), reason="Windows-only path")
def test_windows_job_object_is_cached_across_calls():
    """Repeated calls return the same handle — one job per process, not per spawn."""
    a = _get_or_create_win_job()
    b = _get_or_create_win_job()
    assert a == b, "Job Object handle changed between calls — should be cached"


@pytest.mark.skipif(not _is_windows(), reason="Windows-only path")
def test_windows_install_supervisor_assigns_child_to_job(tmp_path):
    """A spawned subprocess is successfully assigned to the Job Object.

    Verified by IsProcessInJob via the Win32 API. If assignment regressed
    silently (e.g. _install_supervisor became a no-op), this would fail.
    """
    import ctypes

    # Spawn a trivial child that sleeps so we can probe it before it exits.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(5)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        _install_supervisor(child)

        # IsProcessInJob(HANDLE process, HANDLE job, PBOOL result)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.IsProcessInJob.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)
        ]
        kernel32.IsProcessInJob.restype = ctypes.c_int
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel32.CloseHandle.restype = ctypes.c_int
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]

        PROCESS_QUERY_INFORMATION = 0x0400
        proc = kernel32.OpenProcess(PROCESS_QUERY_INFORMATION, 0, child.pid)
        assert proc, "OpenProcess on spawned child failed"
        try:
            result = ctypes.c_int(0)
            job = _get_or_create_win_job()
            ok = kernel32.IsProcessInJob(proc, job, ctypes.byref(result))
            assert ok, "IsProcessInJob API call failed"
            assert result.value == 1, (
                f"Child PID {child.pid} not in the SessionManager Job Object — "
                "_install_supervisor failed to assign it."
            )
        finally:
            kernel32.CloseHandle(proc)
    finally:
        try:
            child.terminate()
            child.wait(timeout=3)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Linux: preexec_fn is wired into the Popen kwargs at spawn time.
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _is_linux(), reason="Linux-only path")
def test_linux_spawn_passes_preexec_fn_pdeathsig(tmp_path, monkeypatch):
    """SessionManager._launch passes _set_pdeathsig as preexec_fn on Linux.

    Verified by intercepting subprocess.Popen and inspecting kwargs.
    """
    captured_kwargs = {}
    real_popen = subprocess.Popen

    def fake_popen(args, **kwargs):
        captured_kwargs.update(kwargs)
        # Spawn a trivial process so the rest of _launch doesn't blow up.
        return real_popen(
            [sys.executable, "-c", "import time; time.sleep(0.1)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            encoding="utf-8",
        )

    monkeypatch.setattr(session_manager.subprocess, "Popen", fake_popen)

    sm = SessionManager(state_dir=tmp_path, claude_bin=str(FAKE_CLAUDE))
    sm.spawn(session_type="preexec-test", display_name="preexec-probe")

    assert "preexec_fn" in captured_kwargs, (
        "preexec_fn was not passed to subprocess.Popen on Linux"
    )
    assert captured_kwargs["preexec_fn"] is _set_pdeathsig, (
        "preexec_fn is not _set_pdeathsig on Linux — supervisor wiring regressed"
    )


@pytest.mark.skipif(not _is_linux(), reason="Linux-only path")
def test_linux_set_pdeathsig_runs_without_exception():
    """_set_pdeathsig must not raise — preexec_fn errors take down the spawn."""
    # Calling in the parent process is harmless: prctl on the parent just
    # sets the parent's own PR_SET_PDEATHSIG, which fires if grandparent
    # dies. The function we care about is that it survives the call.
    _set_pdeathsig()


# ---------------------------------------------------------------------------
# macOS / other POSIX: skip cleanly with a logged note.
# ---------------------------------------------------------------------------


@pytest.mark.skipif(
    _is_windows() or _is_linux(),
    reason="Test specifically covers POSIX-non-Linux fallback",
)
def test_macos_supervisor_skips_cleanly(caplog):
    """_install_supervisor must not raise on macOS / other POSIX even though
    no supervisor primitive is available."""
    # Spawn a trivial child to feed _install_supervisor a real Popen.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(1)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # Should not raise.
        _install_supervisor(child)
    finally:
        try:
            child.terminate()
            child.wait(timeout=3)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Cross-platform: _install_supervisor tolerates dead children gracefully.
# ---------------------------------------------------------------------------


def test_install_supervisor_tolerates_dead_child(tmp_path):
    """If the child has already exited (e.g. crashed during spawn),
    _install_supervisor must not raise. It logs and moves on."""
    child = subprocess.Popen(
        [sys.executable, "-c", ""],  # exits immediately
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    child.wait(timeout=5)
    # Must not raise even though the child is dead.
    _install_supervisor(child)


# ---------------------------------------------------------------------------
# End-to-end: SessionManager.spawn integrates the supervisor primitive.
# ---------------------------------------------------------------------------


def test_session_manager_spawn_installs_supervisor(tmp_path, monkeypatch):
    """SessionManager._launch calls _install_supervisor for every spawn.

    Verified by patching the helper and asserting it was called with the
    spawned child Popen.
    """
    calls = []

    def spy(child):
        calls.append(child)

    monkeypatch.setattr(session_manager, "_install_supervisor", spy)

    # Build a tiny launcher shim that runs fake_claude with the current python.
    if sys.platform == "win32":
        launcher = tmp_path / "claude_launcher.bat"
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{FAKE_CLAUDE}" %*\r\n'
        )
    else:
        launcher = tmp_path / "claude_launcher.sh"
        launcher.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_CLAUDE}" "$@"\n'
        )
        launcher.chmod(0o755)

    sm = SessionManager(state_dir=tmp_path / "state", claude_bin=str(launcher))
    rec = sm.spawn(session_type="supervisor-spy", display_name="spy")

    assert len(calls) == 1, (
        f"_install_supervisor called {len(calls)} times for one spawn — "
        "expected exactly 1"
    )
    assert calls[0] is not None
    assert calls[0].pid is not None

    # Clean up the spawned subprocess.
    sm.archive(rec.id)
