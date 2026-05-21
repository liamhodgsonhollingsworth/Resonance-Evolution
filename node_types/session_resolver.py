"""SessionResolver — name-or-id-prefix → canonical session_id.

Verb: ``resolve`` — given ``name_or_id``, return the matching session's
id via view-state ``last_resolution`` key. Handles four cases:

  - exact-id match: returns the id immediately.
  - unique display-name match (case-insensitive): returns that id.
  - unique id-prefix match (8+ chars): returns that id.
  - ambiguous / unknown: returns None + names the candidates.

This is the canonical resolution primitive. Both surfaces and the
``chat_router`` ``@<name>`` parser route through here so naming
semantics are identical across the system. Lifts from
``tools/workflow_gui/gui_shell.py::_resolve_session_id`` and from
``tools/workflow_streamlit/commands.py::_session_target`` (which had a
weaker version with no prefix matching).
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionResolver",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Resolves a name-or-id-prefix into the canonical session_id. "
            "Detects ambiguity; returns the candidate list when "
            "unique resolution is not possible."
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
    return f"SessionResolver id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "resolve":
        name_or_id = (payload.get("name_or_id") or "").strip()
        result = _resolve(engine, name_or_id)
        return {"last_resolution": result}
    return None


def _resolve(engine: Any, name_or_id: str) -> Dict[str, Any]:
    """Return ``{resolved: bool, session_id: str|None, candidates: list, reason: str}``."""
    if not name_or_id:
        return {
            "resolved": False, "session_id": None,
            "candidates": [], "reason": "empty name_or_id",
        }
    sm = (engine.cache.get("__workflow__") or {}).get("session_manager")
    if sm is None:
        return {
            "resolved": False, "session_id": None,
            "candidates": [], "reason": "no session_manager",
        }
    try:
        records = list(sm.list())
    except Exception as exc:
        return {
            "resolved": False, "session_id": None,
            "candidates": [], "reason": f"sm.list failed: {exc}",
        }

    # 1) exact-id match.
    for rec in records:
        if rec.id == name_or_id:
            return {
                "resolved": True, "session_id": rec.id,
                "candidates": [rec.id], "reason": "exact id",
            }

    # 2) case-insensitive display-name match.
    lower = name_or_id.lower()
    by_name = [rec for rec in records
               if (rec.display_name or "").lower() == lower]
    if len(by_name) == 1:
        return {
            "resolved": True, "session_id": by_name[0].id,
            "candidates": [by_name[0].id], "reason": "unique display_name",
        }
    if len(by_name) > 1:
        return {
            "resolved": False, "session_id": None,
            "candidates": [r.id for r in by_name],
            "reason": f"display_name {name_or_id!r} matches {len(by_name)} sessions",
        }

    # 3) unique id-prefix match (only meaningful for 8+ chars).
    if len(name_or_id) >= 8:
        by_prefix = [rec for rec in records if rec.id.startswith(name_or_id)]
        if len(by_prefix) == 1:
            return {
                "resolved": True, "session_id": by_prefix[0].id,
                "candidates": [by_prefix[0].id], "reason": "unique id-prefix",
            }
        if len(by_prefix) > 1:
            return {
                "resolved": False, "session_id": None,
                "candidates": [r.id for r in by_prefix],
                "reason": f"id-prefix {name_or_id!r} matches {len(by_prefix)} sessions",
            }

    return {
        "resolved": False, "session_id": None,
        "candidates": [],
        "reason": f"no session matches {name_or_id!r}",
    }
