"""
Spawn-and-wait harness for the SPEC-022 orphan-cleanup supervisor test.

This script is launched as a separate Python process by
tests/test_streamjson_orphan_cleanup.py. It:

1. Constructs a SessionManager pointed at the fake-claude fixture.
2. Spawns a stream-json session (this in turn spawns a python child running
   tests/fixtures/fake_claude.py via a launcher shim).
3. Writes the spawned child's PID to a file path passed as argv[1] so the
   test process can read it without parsing our stdout.
4. Sleeps forever (until killed by the test).

The test then sends SIGKILL / TerminateProcess to THIS harness's PID. The
question the supervisor-level test answers: does the child process spawned
in step 2 survive (orphan) or die?

This harness deliberately does NOT register an atexit handler, signal
handler, or sm.shutdown() call — because a real harness OOM / Ctrl+C
between spawn and shutdown is exactly the failure mode under test, and
catchable cleanup would mask it.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: spawn_and_wait_harness.py <pid_file> <state_dir> <claude_launcher>\n"
        )
        return 2

    pid_file = Path(sys.argv[1])
    state_dir = Path(sys.argv[2])
    claude_launcher = sys.argv[3]

    # Make sure the harness can import from the repo root.
    repo_root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(repo_root))

    from tools.workflow.session_manager import SessionManager

    sm = SessionManager(state_dir=state_dir, claude_bin=claude_launcher)
    rec = sm.spawn(session_type="orphan-test", display_name="orphan-probe")

    # Wait until SessionManager has the child PID populated, then publish.
    deadline = time.time() + 5.0
    child_pid = None
    while time.time() < deadline:
        s = sm._sessions.get(rec.id)  # noqa: SLF001 — test-only access
        if s is not None and s.child is not None and s.child.pid:
            child_pid = s.child.pid
            break
        time.sleep(0.05)

    if child_pid is None:
        sys.stderr.write("harness: failed to obtain child pid before timeout\n")
        return 3

    pid_file.write_text(f"{os.getpid()}\n{child_pid}\n")

    # Sleep forever; the test process will kill us. We deliberately do not
    # register a SIGTERM handler or atexit cleanup — the whole point is to
    # simulate a harness that dies between spawn and shutdown.
    while True:
        time.sleep(1.0)


if __name__ == "__main__":
    sys.exit(main())
