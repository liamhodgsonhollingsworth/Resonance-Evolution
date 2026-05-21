"""SessionTarget — track the default routing target across surfaces.

Verbs: ``set`` / ``get``. The maintainer's chat input without an explicit
target lands on whatever this node currently names. Replaces the
file-based ``state/workflow/chat_target.txt`` mechanism (which was
Streamlit-specific) with a node-graph primitive any surface can read.

This separation — target-tracking distinct from sending — is the
maintainer's *"many small composite nodes"* directive in action. The
``chat_router`` composes ``session_target.get`` + ``session_sender.send``
+ ``session_resolver.resolve`` (for ``@<name>``) + the inbox echo.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SessionTarget",
        version="1.0",
        renderer_id="logic",
        inputs={"initial_target": "string"},
        outputs={},
        description=(
            "Tracks the default routing target — the session that "
            "receives chat input when no explicit target is given. "
            "Set/get via engine.actions; persists in view-state."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {"initial_target": params.get("initial_target") or None}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"SessionTarget id={ctx.node.id} initial={state.get('initial_target')!r}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    view = engine.cache.setdefault("__view_state__", {}).setdefault(node.id, {})
    current = view.get("target", state.get("initial_target"))

    if action_name == "set":
        new = payload.get("session_id")  # explicit None resets to no target
        return {"target": new, "last_get": new}
    if action_name == "get":
        return {"last_get": current}
    return None
