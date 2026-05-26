"""
Stubborn-claude fixture for the orphan-cleanup supervisor test.

Unlike `fake_claude.py` which exits cleanly when stdin EOFs, this fixture
ignores stdin entirely and sleeps forever. It models a stream-json
subprocess that survives parent-pipe-close — the real-world failure mode
deferred-concerns #20 names (a `claude` process busy on tool-use that
hasn't returned to its stdin read loop yet, or a hung tool-call subprocess).

The supervisor-level test uses this fixture to confirm the orphan-probe
DOES catch a real orphan when one exists, so the absence of an orphan in
the fake-claude variant is a credible "cleanup is sufficient" signal
rather than a test bug.
"""

from __future__ import annotations

import json
import sys
import time
import uuid


def main() -> int:
    sys.stdout.write(json.dumps({
        "type": "system",
        "subtype": "init",
        "session_id": str(uuid.uuid4()),
    }) + "\n")
    sys.stdout.flush()

    # Deliberately do NOT read stdin. Sleep forever and ignore SIGTERM /
    # parent-pipe-close. The test will kill us via PID tree-kill in the
    # finally block.
    while True:
        time.sleep(1.0)


if __name__ == "__main__":
    sys.exit(main())
