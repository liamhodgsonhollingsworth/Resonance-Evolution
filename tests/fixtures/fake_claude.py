"""
Fake-claude script for SessionManager tests.

Speaks the same stream-json shape the real claude CLI uses:
- Reads JSON envelopes from stdin (one per line): {"type": "user",
  "message": {"role": "user", "content": "..."}}
- Writes JSON events to stdout, one per line: assistant/text, result, etc.
- For "trigger-unknown-event" inputs, emits an event of an unknown type
  to validate the SessionManager's drift-tolerant dispatch.

Used by tests/test_workflow_session_manager.py via a thin shell/.bat
launcher that runs this with the current python interpreter.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid


_NODE_TYPE_TEMPLATE = '''"""TestClock node-type written by fake_claude for integration test."""

from engine.node import Manifest


def manifest():
    return Manifest(
        name="TestClock",
        version="1.0",
        renderer_id="raster",
        description="Test-only node-type written hot-via-fake-claude.",
    )


def build(params):
    return {"hello": "world"}


def emit(state, view, ctx):
    return {}


def describe(state, ctx):
    return "TestClock@now"
'''


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main() -> int:
    # Optional: spawn a long-lived "grandchild" before reading input.
    # Used by tests/test_session_manager_tree_kill.py to verify
    # SessionManager.archive walks the process tree on Windows (the
    # cmd.exe wrapper -> fake_claude -> grandchild chain mirrors
    # cmd.exe -> claude -> any-claude-child in production). The path
    # the grandchild PID is published to is taken from
    # FAKE_CLAUDE_GRANDCHILD_PID_FILE; absent => no grandchild.
    grandchild_pid_file = os.environ.get("FAKE_CLAUDE_GRANDCHILD_PID_FILE")
    if grandchild_pid_file:
        import subprocess  # local import keeps the no-grandchild path tiny
        # The grandchild itself is just a python process that sleeps.
        # We use sys.executable so the test doesn't depend on `sleep`
        # being on PATH (Windows-friendly).
        gc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(3600)"],
        )
        # Publish atomically: write to a temp sibling then rename, so
        # a test that reads the file mid-write doesn't see a partial
        # PID. Path.replace is atomic on Windows + POSIX.
        from pathlib import Path as _Path
        target = _Path(grandchild_pid_file)
        tmp = target.with_suffix(target.suffix + ".part")
        tmp.write_text(str(gc.pid), encoding="utf-8")
        tmp.replace(target)

    # Emit a system/init event up-front so the SessionManager sees a
    # plausible boot sequence.
    _emit({"type": "system", "subtype": "init", "session_id": str(uuid.uuid4())})

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            env = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if env.get("type") != "user":
            continue
        body = (env.get("message") or {}).get("content", "")
        if isinstance(body, list):
            # tool result envelopes have list content; not relevant here
            continue
        if "trigger-unknown-event" in body:
            _emit({"type": "weird_new_event_type", "payload": {"x": 1}})
            _emit({"type": "result", "duration_ms": 5, "total_cost_usd": 0.0, "usage": {}, "is_error": False})
            continue
        if body.startswith("WRITE_NODE_TYPE "):
            # Test directive: write a minimal node-type file the workflow
            # shell + file-watcher should pick up. Format:
            #   WRITE_NODE_TYPE <abs-path>
            # The script writes a tiny working node-type module to the
            # given absolute path, then emits a completion message.
            target = body[len("WRITE_NODE_TYPE "):].strip()
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(_NODE_TYPE_TEMPLATE)
            _emit({
                "type": "assistant",
                "message": {
                    "id": str(uuid.uuid4()),
                    "content": [
                        {"type": "text", "text": f"wrote {target}"},
                    ],
                },
            })
            _emit({
                "type": "result",
                "duration_ms": 5,
                "total_cost_usd": 0.0,
                "usage": {},
                "is_error": False,
            })
            continue
        # Echo back: emit an assistant message and a result.
        _emit({
            "type": "assistant",
            "message": {
                "id": str(uuid.uuid4()),
                "content": [
                    {"type": "text", "text": f"echo: {body}"},
                ],
            },
        })
        _emit({
            "type": "result",
            "duration_ms": 10,
            "total_cost_usd": 0.0001,
            "usage": {"input_tokens": 1, "output_tokens": 4},
            "is_error": False,
        })
    return 0


if __name__ == "__main__":
    sys.exit(main())
