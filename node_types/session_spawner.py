"""SessionSpawner — spawn a new claude session via SessionManager.

Verb: ``spawn`` — payload ``{session_type, display_name?, seed_message?, cwd?}``.
Returns the new session record via view-state ``last_spawn`` key.
Wraps ``SessionManager.spawn`` so the spawn pathway is uniformly
reachable from any surface and from any MCP-tool caller.
"""

from __future__ import annotations

from dataclasses import asdict
from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionSpawner",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Spawns a new claude session via SessionManager. Exposes "
            "the spawn primitive uniformly across every surface."
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
    return f"SessionSpawner id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "spawn":
        session_type = payload.get("session_type") or "general"
        display_name = payload.get("display_name") or None
        seed_message = payload.get("seed_message") or None
        cwd = payload.get("cwd") or None
        sm = (engine.cache.get("__workflow__") or {}).get("session_manager")
        if sm is None:
            return {"last_spawn": {"spawned": False, "reason": "no session_manager"}}
        try:
            rec = sm.spawn(
                session_type=session_type,
                display_name=display_name,
                seed_message=seed_message,
                cwd=cwd,
            )
        except Exception as exc:
            return {"last_spawn": {"spawned": False, "reason": f"sm.spawn failed: {exc}"}}
        try:
            record_dict = asdict(rec)
        except Exception:
            record_dict = {
                "id": getattr(rec, "id", None),
                "display_name": getattr(rec, "display_name", None),
                "status": getattr(rec, "status", None),
            }
        return {"last_spawn": {
            "spawned": True, "session_id": rec.id, "record": record_dict,
            "reason": f"spawned {rec.id}",
        }}
    return None
