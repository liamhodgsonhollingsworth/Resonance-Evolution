"""
Light — a directional light source. Has no visual contribution of its
own (emit returns empty channels). Its purpose is to register itself in
the engine's shared lights cache at precompute time, so renderer-nodes
that do lighting calculations can read it.

Demonstrates the "logic-as-node + cache as shared state" pattern: any
node-type can register information at precompute time that other
node-types consume at emit time, via the same engine.cache used by
Aggregator's BehaviorSummary. New kinds of lights (point, spot, area)
become new node-types that register richer metadata; the consumer
side (LambertianShader, etc.) gets new lights for free.
"""

import numpy as np
from typing import List

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Light",
        version="1.0",
        renderer_id="raster",
        inputs={"direction": "vec3", "color": "vec3", "intensity": "float"},
        outputs={},
        description=(
            "A directional light. Registers itself in engine.cache['__lights__'] "
            "at precompute time so shader-renderers can consume it."
        ),
    )


def build(params):
    direction = np.asarray(params.get("direction", [0.0, -1.0, -0.5]), dtype=np.float32)
    norm = np.linalg.norm(direction)
    if norm > 1e-9:
        direction = direction / norm
    return {
        "direction": direction,
        "color": np.asarray(params.get("color", [1.0, 1.0, 1.0]), dtype=np.float32),
        "intensity": float(params.get("intensity", 1.0)),
    }


def precompute_hook(state, engine, node):
    """Append this light to the shared __lights__ list in the engine cache."""
    lights = engine.cache.setdefault("__lights__", [])
    lights.append({
        "node_id": node.id,
        "direction": state["direction"],
        "color": state["color"],
        "intensity": state["intensity"],
    })
    return {"registered": True}


def select_children(state, view: View, engine, node) -> List[str]:
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    # Lights have no visual contribution themselves; they're just info
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    d = state["direction"]
    c = state["color"]
    return (f"Light id={ctx.node.id} "
            f"dir=[{d[0]:.2f}, {d[1]:.2f}, {d[2]:.2f}] "
            f"color=[{c[0]:.2f}, {c[1]:.2f}, {c[2]:.2f}] "
            f"intensity={state['intensity']:.2f}")
