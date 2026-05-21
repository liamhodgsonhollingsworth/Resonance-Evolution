"""SessionSender — write a body to one session's stdin.

Verb: ``send`` — payload ``{session_id, body}``. Calls
``SessionManager.send(session_id, body)``. Returns a result dict via
view-state ``last_send`` key. The simplest possible delivery
primitive; composes with ``session_resolver`` (for name → id) and
``chat_router`` (for echo + delivery).
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionSender",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Delivers one body to one session via SessionManager.send. "
            "Composes with SessionResolver for name-based routing."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"SessionSender id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "send":
        sid = payload.get("session_id") or ""
        body = payload.get("body") or ""
        result = _send(engine, sid, body)
        return {"last_send": result}
    return None


def _send(engine: Any, sid: str, body: str) -> Dict[str, Any]:
    if not sid:
        return {"sent": False, "session_id": sid, "reason": "empty session_id"}
    if not body:
        return {"sent": False, "session_id": sid, "reason": "empty body"}
    sm = (engine.cache.get("__workflow__") or {}).get("session_manager")
    if sm is None:
        return {"sent": False, "session_id": sid, "reason": "no session_manager"}
    try:
        sm.send(sid, body)
    except Exception as exc:
        return {"sent": False, "session_id": sid, "reason": f"sm.send failed: {exc}"}
    return {"sent": True, "session_id": sid, "reason": f"delivered to {sid}"}
