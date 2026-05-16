"""
AsciiDebug — text-mode visualizer for testing topology before the
visuals work. Renders the depth channel of its sub-graph as ASCII art.

Useful for verifying that the scene is geometrically correct from the
viewer's position without needing to open the rendered PNG.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="AsciiDebug",
        version="1.0",
        renderer_id="ascii",
        outputs={"text": "string", "color": "rgb_image", "depth": "depth_image"},
        description="Renders the depth channel as ASCII art for text-mode topology debugging.",
    )


def build(params):
    return {
        "width": int(params.get("width", 64)),
        "height": int(params.get("height", 24)),
        "ramp": params.get("ramp", " .:-=+*#%@"),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    # Force the wrapped sub-graph to render at our internal resolution
    inner_view = View(
        position=view.position,
        orientation=view.orientation,
        scale=view.scale,
        width=state["width"],
        height=state["height"],
        fov_y_radians=view.fov_y_radians,
    )
    composited = ctx.engine._composite_children(
        {k: (n, _resize_or_passthrough(ch, state["width"], state["height"])) for k, (n, ch) in ctx.child_outputs.items()},
        inner_view,
    )

    depth = composited.get("depth")
    text_art = _depth_to_ascii(depth, state["ramp"]) if depth is not None else "(no depth channel)"

    return {
        "color": composited.get("color"),
        "depth": composited.get("depth"),
        "text": text_art,
    }


def describe(state, ctx: EmitContext) -> str:
    return f"AsciiDebug id={ctx.node.id} resolution={state['width']}x{state['height']}"


def _depth_to_ascii(depth: np.ndarray, ramp: str) -> str:
    finite = depth[np.isfinite(depth)]
    if finite.size == 0:
        return "(no surfaces hit)"
    lo, hi = float(finite.min()), float(finite.max())
    if hi - lo < 1e-9:
        return "(uniform depth)"
    normalized = np.where(np.isfinite(depth), 1.0 - (depth - lo) / (hi - lo), 0.0)
    n = len(ramp) - 1
    idx = np.clip((normalized * n).astype(int), 0, n)
    lines = []
    for row in idx:
        lines.append("".join(ramp[i] for i in row))
    return "\n".join(lines)


def _resize_or_passthrough(channels: Channels, w: int, h: int) -> Channels:
    # The wrapped children rendered at the outer view's resolution, not ours.
    # For first version, we just pass them through; a future version would
    # re-render the sub-graph at our resolution. The compositor handles
    # mismatches by best-effort.
    return channels
