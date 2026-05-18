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
            import os
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
