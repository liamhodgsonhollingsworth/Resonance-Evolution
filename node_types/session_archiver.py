"""SessionArchiver — archive a session via SessionManager.archive.

Verb: ``archive`` — payload ``{session_id}``. Marks the session as
archived (terminates the subprocess + flips the record status).
Returns result via view-state ``last_archive`` key.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionArchiver",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Archives a session via SessionManager.archive. "
            "Renderer-neutral archive primitive."
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
    return f"SessionArchiver id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "archive":
        sid = payload.get("session_id") or ""
        if not sid:
            return {"last_archive": {"archived": False, "reason": "empty session_id"}}
        sm = (engine.cache.get("__workflow__") or {}).get("session_manager")
        if sm is None:
            return {"last_archive": {"archived": False, "session_id": sid,
                                     "reason": "no session_manager"}}
        try:
            sm.archive(sid)
        except Exception as exc:
            return {"last_archive": {"archived": False, "session_id": sid,
                                     "reason": f"sm.archive failed: {exc}"}}
        return {"last_archive": {"archived": True, "session_id": sid,
                                 "reason": f"archived {sid}"}}
    return None
