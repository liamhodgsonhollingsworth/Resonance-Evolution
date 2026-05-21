"""SessionLister — exposes SessionManager.list() as an engine action.

One small logic node. Verb: ``refresh`` — re-read the SessionManager
and write the list of session records into this node's view-state at
the ``sessions`` key. Other nodes / surfaces consume the list via
``engine.actions.get_view_state(engine, 'session_lister_main')``.

Pairs with ``session_resolver``, ``session_sender``, ``session_spawner``,
``session_archiver``, ``session_target`` — the maintainer's 2026-05-21
directive to *"separate as many nodes as possible into composite nodes
that are all linked together"*. Each is its own small handler; cross-node
composition lives in higher nodes (e.g. ``chat_router`` for /all).
"""

from __future__ import annotations

from dataclasses import asdict
from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionLister",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Reads SessionManager.list() and exposes the record list "
            "via view-state under the 'sessions' key. Other nodes + "
            "the surfaces consume the list by querying view-state."
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
    return f"SessionLister id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "refresh":
        sm = (engine.cache.get("__workflow__") or {}).get("session_manager")
        if sm is None:
            return {"sessions": [], "error": "no session_manager"}
        try:
            records = list(sm.list())
        except Exception as exc:
            return {"sessions": [], "error": f"sm.list failed: {exc}"}
        # Serialize records so callers don't depend on SessionRecord internals.
        out = []
        for rec in records:
            try:
                out.append(asdict(rec))
            except Exception:
                out.append({
                    "id": getattr(rec, "id", None),
                    "display_name": getattr(rec, "display_name", None),
                    "status": getattr(rec, "status", None),
                })
        return {"sessions": out, "error": None}
    return None
