"""
GravityField — a region with its own gravity vector.

Demonstrates the "logic-as-node + shared cache" pattern: at precompute
time the node registers its region+vector in engine.cache["__gravity_fields__"];
input-handling code (input.py and future interactive renderer) queries
the list to find which field contains the viewer and overrides
view.gravity_up accordingly.

State carries an axis-aligned bounding region (center + half-extent) plus
the gravity vector for that region. v1 ships a single shape; future
shapes are new node-type files.

No visual emit — this is a logic-only node. describe() surfaces the
state to the text-renderer.
"""

from __future__ import annotations

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="GravityField",
        version="1.0",
        renderer_id="raster",
        inputs={"center": "vec3", "half_extent": "vec3", "gravity": "vec3"},
        outputs={},
        description=(
            "Axis-aligned region carrying its own gravity vector. "
            "Registers in engine.cache['__gravity_fields__'] for the "
            "input system to consult. No visual emit."
        ),
    )


def build(params):
    return {
        "center": np.asarray(params.get("center", [0.0, 0.0, 0.0]), dtype=np.float64),
        "half_extent": np.asarray(params.get("half_extent", [1e9, 1e9, 1e9]), dtype=np.float64),
        "gravity": np.asarray(params.get("gravity", [0.0, -9.81, 0.0]), dtype=np.float64),
    }


def precompute_hook(state, engine, node):
    """Register this field in the shared field list."""
    engine.cache.setdefault("__gravity_fields__", []).append({
        "node_id": node.id,
        "center": state["center"],
        "half_extent": state["half_extent"],
        "gravity": state["gravity"],
    })
    return {"registered": True}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """No visual contribution."""
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    c, e, g = state["center"], state["half_extent"], state["gravity"]
    return (f"GravityField id={ctx.node.id} "
            f"center=[{c[0]:.2f},{c[1]:.2f},{c[2]:.2f}] "
            f"half_extent=[{e[0]:.2f},{e[1]:.2f},{e[2]:.2f}] "
            f"gravity=[{g[0]:.2f},{g[1]:.2f},{g[2]:.2f}]")


# ---------------------------------------------------------------------------
# Helper for the input system: find the active field at a world position.
# ---------------------------------------------------------------------------


def active_field(engine, position: np.ndarray):
    """Return the first registered field containing `position`, or None.
    The input system queries this when computing the viewer's effective
    gravity_up vector. Fields registered later override earlier ones, so
    a small interior field can override a large global one — useful for
    nested gravity zones."""
    fields = engine.cache.get("__gravity_fields__", [])
    for f in reversed(fields):
        delta = position - f["center"]
        if np.all(np.abs(delta) <= f["half_extent"]):
            return f
    return None
