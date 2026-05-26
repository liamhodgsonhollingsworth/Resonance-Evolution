"""
Supervisor-level test for SPEC-022 stream-json subprocess management.

Origin: Deferred-concerns entry #20 (Alethea
`notes/website_planning_arc/post_migration_deferred_concerns.md`). The
adversarial walk in Phase 1b A4 surfaced a gap: SessionManager has no test
asserting that the stream-json subprocess gets cleaned up if the test
harness ITSELF crashes between spawn and shutdown (e.g. harness OOM, manual
Ctrl+C). Process-supervisor scope, not unit-test scope - hence this file
sits separately from `tests/test_workflow_session_manager.py` and is
excluded from the default pytest run via the `supervisor` mark.

How it works
------------
1. A child Python process (`tests/fixtures/spawn_and_wait_harness.py`)
   constructs a SessionManager, spawns a fake-claude session, publishes
   `(harness_pid, child_pid)` to a temp file, and sleeps.
2. The test reads the temp file to obtain both PIDs.
3. The test KILLS the harness with a non-catchable signal (`taskkill /F`
   on Windows, `SIGKILL` on Unix). This simulates harness OOM / Ctrl+C
   between spawn and shutdown - the scenarios deferred-concerns #20 names.
4. The test waits briefly, then probes the OS process table for the child
   PID. If the child is still alive, the harness leaked an orphan.

Two complementary scenarios
---------------------------
A. `fake_claude` - exits on stdin EOF. When the harness dies, the
   stdin pipe closes, fake_claude reads EOF, returns from main(), exits
   cleanly. The OS-level pipe semantics propagate cleanup without any
   supervisor-level Job-Object / PDEATHSIG registration. The test
   ASSERTS no orphan - if this regresses, something in the
   SessionManager / pipe lifecycle changed.

B. `stubborn_claude` - ignores stdin, sleeps forever. Models a real
   `claude` process busy on a tool-use that hasn't returned to its
   stdin-read loop yet, or any long-running tool subprocess. Without
   supervisor-level cleanup (Windows Job Object / POSIX
   PR_SET_PDEATHSIG), the OS does NOT reap the child when the parent
   dies uncatchably. The test recognises the orphan via `xfail` so the
   suite stays green but the gap is loudly visible in the pytest
   report. Also serves as the sanity arm: it proves the probe DOES
   catch a real orphan when one exists, so scenario A's pass is a
   credible "cleanup sufficient for that scenario" signal rather than
   a test bug.

If a future change registers stream-json children with a Job Object
(Windows: CREATE_BREAKAWAY_FROM_JOB cleared + AssignProcessToJobObject
with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) or POSIX prctl
PR_SET_PDEATHSIG, scenario B will flip from xfail to XPASS - that's
the regression signal to update the assertion.

Running
-------
By default `pytest tests/` does NOT pick this up because the
`supervisor` mark is excluded in pyproject.toml's `addopts`. Run
explicitly with:

    pytest tests/test_streamjson_orphan_cleanup.py -v
    pytest -m supervisor                              # all supervisor tests

Or via the bundled launcher:

    python tests/test_streamjson_orphan_cleanup.py
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest


pytestmark = pytest.mark.supervisor


HERE = Path(__file__).resolve().parent
HARNESS = HERE / "fixtures" / "spawn_and_wait_harness.py"
FAKE_CLAUDE = HERE / "fixtures" / "fake_claude.py"
STUBBORN_CLAUDE = HERE / "fixtures" / "stubborn_claude.py"


# --------------------------------------------------------------------------
# OS-level process probing - no psutil dependency.
# --------------------------------------------------------------------------


def _pid_alive(pid: int) -> bool:
    """True if a process with `pid` is currently in the OS process table."""
    if os.name == "nt":
        # tasklist /FI "PID eq <pid>" /NH - prints a single line if found,
        # or "INFO: No tasks are running..." if not.
        try:
            out = subprocess.check_output(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=5.0,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            return False
        return str(pid) in out and "No tasks" not in out
    # POSIX: signal 0 is a no-op that only checks for existence.
    try:
        os.kill(pid, 0)
    except (OSError, ProcessLookupError):
        return False
    return True


def _kill_pid(pid: int, force_tree: bool = False) -> None:
    """Best-effort kill of a single PID. Non-fatal if pid is already gone."""
    if os.name == "nt":
        args = ["taskkill", "/F", "/PID", str(pid)]
        if force_tree:
            args.insert(1, "/T")
        try:
            subprocess.run(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5.0,
                check=False,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass


def _make_claude_launcher(tmp_path: Path, claude_script: Path = FAKE_CLAUDE) -> str:
    """Build a shim that lets SessionManager `spawn` the given claude-shaped script."""
    if os.name == "nt":
        launcher = tmp_path / "claude_launcher.bat"
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{claude_script}" %*\r\n'
        )
    else:
        launcher = tmp_path / "claude_launcher.sh"
        launcher.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{claude_script}" "$@"\n'
        )
        launcher.chmod(0o755)
    return str(launcher)


def _wait_for_file_nonempty(path: Path, timeout_s: float) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            try:
                if path.stat().st_size > 0:
                    return True
            except OSError:
                pass
        time.sleep(0.05)
    return False


# --------------------------------------------------------------------------
# Driver - one harness-killed-uncatchably scenario.
# --------------------------------------------------------------------------


def _run_orphan_probe(tmp_path: Path, claude_script: Path) -> tuple[int, int, bool]:
    """
    Returns (harness_pid, child_pid, child_orphaned).

    Self-isolating: the `finally` block kills any pids still alive after
    the observation has been recorded, so the broader test suite stays
    clean even when an orphan is found.
    """
    pid_file = tmp_path / "harness_pids.txt"
    state_dir = tmp_path / "state"
    claude_launcher = _make_claude_launcher(tmp_path, claude_script)

    repo_root = HERE.parent
    env = os.environ.copy()
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (
        f"{repo_root}{os.pathsep}{existing}" if existing else str(repo_root)
    )

    harness_proc = subprocess.Popen(
        [sys.executable, str(HARNESS), str(pid_file), str(state_dir), claude_launcher],
        cwd=str(repo_root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    harness_pid = harness_proc.pid
    child_pid: int | None = None

    try:
        # Wait until the harness publishes both PIDs.
        assert _wait_for_file_nonempty(pid_file, timeout_s=15.0), (
            "harness did not publish PIDs to pid_file; "
            "stderr: "
            + (harness_proc.stderr.read().decode("utf-8", errors="replace")
               if harness_proc.stderr else "")
        )

        lines = pid_file.read_text().strip().splitlines()
        assert len(lines) >= 2, f"pid_file contents malformed: {lines!r}"
        published_harness_pid = int(lines[0].strip())
        child_pid = int(lines[1].strip())
        assert published_harness_pid == harness_pid

        # Sanity: both processes should be alive right now.
        assert _pid_alive(harness_pid), "harness died before we could kill it"
        assert _pid_alive(child_pid), "child subprocess not alive immediately after spawn"

        # KILL the harness with a non-catchable signal. The harness has no
        # SIGTERM handler, no atexit hook, no shutdown call - this models
        # OS-level harness death between spawn and shutdown.
        _kill_pid(harness_pid, force_tree=False)

        # Wait for the harness PID to clear from the process table.
        deadline = time.time() + 10.0
        while time.time() < deadline and _pid_alive(harness_pid):
            time.sleep(0.1)
        assert not _pid_alive(harness_pid), "harness refused to die"

        # Give the OS a moment to reap any tree the harness might have owned.
        time.sleep(2.0)

        # NOW: does the stream-json child survive?
        child_orphaned = _pid_alive(child_pid)

        # Emit a single-line outcome record so the test log makes the
        # observation explicit on read-back.
        print(
            f"\n[SPEC-022 orphan-probe] harness_pid={harness_pid} "
            f"child_pid={child_pid} child_orphaned={child_orphaned} "
            f"claude_script={claude_script.name}"
        )

        return harness_pid, child_pid, child_orphaned

    finally:
        # Defensive cleanup: kill any pids we know about that are still
        # alive. The observation was already recorded above, so this only
        # affects cleanup, not the test signal.
        if child_pid is not None and _pid_alive(child_pid):
            _kill_pid(child_pid, force_tree=True)
            time.sleep(0.5)
            if _pid_alive(child_pid):
                _kill_pid(child_pid, force_tree=False)
        if _pid_alive(harness_pid):
            _kill_pid(harness_pid, force_tree=True)
        try:
            harness_proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            pass


# --------------------------------------------------------------------------
# The two supervisor-level tests.
# --------------------------------------------------------------------------


def test_streamjson_subprocess_cleanup_with_pipe_eof_child(tmp_path):
    """
    Scenario A: the spawned subprocess exits cleanly when its stdin pipe
    closes (which happens automatically when the harness dies and its
    open stdin handle to the child closes).

    EXPECTED on the current implementation: the child is NOT orphaned -
    OS pipe-EOF semantics propagate cleanup even without supervisor-level
    process-group / job-object registration. The test PASSES, documenting
    the positive outcome for this category of stream-json subprocess.
    """
    _, _, child_orphaned = _run_orphan_probe(tmp_path, FAKE_CLAUDE)
    assert not child_orphaned, (
        "fake_claude exits on stdin EOF, so the orphan-probe should "
        "have observed no orphan. If this assertion fails, something "
        "in the SessionManager / pipe lifecycle changed and a real "
        "orphan was leaked even for the easy case."
    )


def test_streamjson_subprocess_orphans_when_child_ignores_stdin(tmp_path):
    """
    Scenario B: the spawned subprocess IGNORES stdin and sleeps forever.
    Models a real `claude` process busy on a tool-use that hasn't
    returned to its stdin-read loop, or any long-running tool
    subprocess.

    EXPECTED on the current implementation: the child IS orphaned - no
    supervisor-level cleanup (Windows Job Object / POSIX
    PR_SET_PDEATHSIG) is registered, so the OS does not reap the child
    when the parent dies uncatchably. The test recognises the orphan
    via xfail so the suite stays green but the gap is loudly visible in
    the pytest report.

    This is the SANITY-CHECK arm of the orphan-probe: it proves the
    probe DOES catch a real orphan when one exists, so the positive
    outcome of `test_streamjson_subprocess_cleanup_with_pipe_eof_child`
    above is a credible "cleanup sufficient for that scenario" signal
    rather than a test bug.

    If a future change registers stream-json children with a Job Object
    or equivalent, this test will flip to "no orphan" and the xfail
    will turn into XPASS - promote it to a plain pass-asserting test
    and update the finding section in the PR description.
    """
    _, child_pid, child_orphaned = _run_orphan_probe(tmp_path, STUBBORN_CLAUDE)
    if not child_orphaned:
        # Pleasant surprise: supervisor-level cleanup IS sufficient even
        # for the stubborn-child case. Test PASSES.
        return
    pytest.xfail(
        f"SPEC-022 orphan confirmed (stubborn-child PID {child_pid} "
        "survived non-catchable harness death). Production-code fix "
        "would register stream-json children with a Windows Job Object "
        "(CREATE_BREAKAWAY_FROM_JOB cleared + AssignProcessToJobObject "
        "with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) or POSIX "
        "PR_SET_PDEATHSIG so the OS reaps the child on parent death. "
        "Out of scope for the test-only arc; flagged for Wave 2 follow-up."
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v", "-rs"]))
