"""StreamlitPanel — a scene-declarable pointer to a Streamlit panel.

Closes the parallel-registry gap surfaced in the 2026-05-21
bare-minimum-criterion-2 audit. Before this node-type, the Streamlit
panel layer lived entirely in ``tools/workflow_streamlit/panels/`` and
was discovered by a separate filesystem walk; the engine's scene
graph had no awareness of which panels existed. The maintainer
reading ``scenes/workflow_view.json`` could not learn anything about
the Streamlit panels because they were invisible to the scene.

This node-type is the declarative side of the bridge. Each scene
entry of type ``StreamlitPanel`` carries a ``panel_name`` parameter
that names a panel module in ``tools/workflow_streamlit/panels/``
(e.g. ``chat``, ``auth``, ``session-status``). Optional params
override the mount point or order from the panel's own manifest.

The Streamlit driver consults both sources at render time:
  - Filesystem-discovered panels (existing path), and
  - Engine-declared StreamlitPanel instances (new path).

Both produce the same ``RegisteredPanel`` shape downstream, so the
driver is source-agnostic. A panel that appears in the scene gets
the order/mount overrides; a panel that appears only on disk gets
the defaults from its own manifest.

The deeper architectural lift — moving panel implementation files
themselves into ``node_types/`` — remains. This node-type is the
incremental bridge that lets the scene declare panels today without
that bigger refactor.

Verbs:
  - ``list`` — return every StreamlitPanel instance in the engine,
    with the resolved (panel_name, mount_point, order) tuple. Surfaces
    that any caller (the driver, an MCP-tool inspector, the maintainer
    via the bottom terminal) can read.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="StreamlitPanel",
        version="1.0",
        renderer_id="streamlit-panel",
        inputs={
            "panel_name": "string",
            "mount_point": "string",
            "order": "int",
            "hidden": "bool",
        },
        outputs={},
        description=(
            "Scene-declared pointer to a Streamlit panel module. Lets "
            "scenes/workflow_view.json enumerate every panel the page "
            "should render, in declaration order, with mount-point + "
            "ordering overrides. Bridges the engine scene graph and "
            "the Streamlit panel registry."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    name = (params.get("panel_name") or "").strip()
    mount = (params.get("mount_point") or "").strip() or None
    order = params.get("order")
    if order is not None:
        try:
            order = int(order)
        except (TypeError, ValueError):
            order = None
    hidden = bool(params.get("hidden", False))
    return {
        "panel_name": name,
        "mount_point": mount,
        "order": order,
        "hidden": hidden,
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return (
        f"StreamlitPanel id={ctx.node.id} "
        f"panel_name={state.get('panel_name')!r} "
        f"mount={state.get('mount_point')!r} order={state.get('order')!r}"
    )


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "list":
        # Walk engine.nodes for every StreamlitPanel instance and emit
        # the resolved panel descriptors. Order is the order the scene
        # declared them in (engine.nodes is dict-insertion-ordered).
        panels = []
        for nid, inst in engine.nodes.items():
            if getattr(inst, "type_name", None) != "StreamlitPanel":
                continue
            params = inst.state if hasattr(inst, "state") else {}
            panels.append({
                "node_id": nid,
                "panel_name": params.get("panel_name"),
                "mount_point": params.get("mount_point"),
                "order": params.get("order"),
                "hidden": bool(params.get("hidden", False)),
            })
        return {"last_list": panels}

    return None
