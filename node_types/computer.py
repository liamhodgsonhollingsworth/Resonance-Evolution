"""
Computer — a node-type that owns the rendering of its "running" sub-graph
and pastes the result onto a rectangular screen surface in the outer
world. Demonstrates two architectural commitments:

  - Renderer-as-node + screen-region ownership. The Computer owns both
    a screen-area in outer world space AND the camera that renders its
    sub-graph. The screen is one region of the outer frame; the rest
    of the frame passes through to other geometry via transparent
    pixels. Different screens in the same scene can run different
    sub-graphs at different internal resolutions, different FOVs.

  - Recursive worlds, unbounded. The sub-graph the Computer renders
    can itself contain Computers; recursion just falls out of the
    engine's normal traversal. No depth-handling needed beyond
    avoiding cycles (don't make a Computer's "running" reference
    itself transitively).

The "running" connection points to whatever sub-graph is on the screen.
The Computer ignores the engine's default recursion via select_children
returning [] — it wants full control of how its sub-graph is rendered,
including the internal camera position, target, FOV, and resolution.
Without the skip, the engine would emit the sub-graph once under the
outer view, then Computer would emit it again at the internal view —
wasted work that the precomputation-moves-heavy-work-to-build-time
commitment forbids.

For v1 the internal camera is fixed by state. For v2 it can be viewer-
aware (follows the outer viewer position), or focus-aware (the Computer
takes over the whole frame when the viewer focuses on it). Both
extensions preserve Computer's interface (manifest, select_children,
emit signatures).
"""

import numpy as np
from typing import List

from engine.node import Channels, EmitContext, Manifest, View, look_at


def manifest() -> Manifest:
    return Manifest(
        name="Computer",
        version="1.0",
        renderer_id="raster",
        inputs={
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            "internal_camera_position": "vec3",
            "internal_camera_target": "vec3",
            "internal_fov_y_radians": "float",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "A rectangular screen in the outer world that displays the "
            "render of its 'running' sub-graph from a fixed internal "
            "camera. Demonstrates recursive-renderer + screen-region-"
            "ownership; the sub-graph can itself contain Computers."
        ),
    )


def build(params):
    return {
        "screen_width": float(params.get("screen_width", 3.0)),
        "screen_height": float(params.get("screen_height", 2.0)),
        "screen_resolution": int(params.get("screen_resolution", 128)),
        "internal_camera_position": np.asarray(
            params.get("internal_camera_position", [0.0, 0.0, 5.0]),
            dtype=np.float64,
        ),
        "internal_camera_target": np.asarray(
            params.get("internal_camera_target", [0.0, 0.0, 0.0]),
            dtype=np.float64,
        ),
        "internal_fov_y_radians": float(
            params.get("internal_fov_y_radians", np.pi / 4)
        ),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Computer fully manages its sub-graph's render — don't let the
    engine emit it under the outer view. emit() calls engine.assemble()
    explicitly with the internal view."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    out_w, out_h = view.width, view.height
    screen_w = state["screen_width"]
    screen_h = state["screen_height"]
    internal_max = state["screen_resolution"]

    running = ctx.node.connections.get("running")
    if running is None:
        # No software running — blank screen surface
        return _render_screen_rectangle(
            view, screen_w, screen_h,
            fill_color=np.array([0.05, 0.05, 0.08], dtype=np.float32),
            internal_color=None,
        )

    # Internal render dimensions match screen aspect so the sub-graph
    # isn't squashed when sampled onto a non-square screen.
    aspect = screen_w / screen_h
    if aspect >= 1.0:
        internal_w = internal_max
        internal_h = max(1, int(round(internal_max / aspect)))
    else:
        internal_h = internal_max
        internal_w = max(1, int(round(internal_max * aspect)))

    target_id = _resolve_target(running)
    internal_view = View(
        position=state["internal_camera_position"].copy(),
        orientation=look_at(
            state["internal_camera_position"],
            state["internal_camera_target"],
        ),
        width=internal_w,
        height=internal_h,
        fov_y_radians=state["internal_fov_y_radians"],
    )
    internal_channels = ctx.engine.assemble(target_id, internal_view)
    internal_color = internal_channels.get("color")
    if internal_color is None:
        internal_color = np.zeros((internal_h, internal_w, 3), dtype=np.float32)

    return _render_screen_rectangle(
        view, screen_w, screen_h,
        fill_color=None,
        internal_color=internal_color,
    )


def describe(state, ctx: EmitContext) -> str:
    running = ctx.node.connections.get("running")
    target_id = _resolve_target(running) if running is not None else "(none)"
    return (f"Computer id={ctx.node.id} "
            f"screen={state['screen_width']:.2f}x{state['screen_height']:.2f} "
            f"@{state['screen_resolution']}px running={target_id}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_target(conn):
    if isinstance(conn, str):
        return conn
    if isinstance(conn, dict):
        return conn["target"]
    if isinstance(conn, list):
        return conn[0]
    raise ValueError(f"unrecognized connection: {conn!r}")


def _render_screen_rectangle(view: View, screen_w: float, screen_h: float,
                             fill_color, internal_color):
    """Ray-cast the outer view against a screen rectangle in the XY plane
    at z=0, paste internal_color via UV sampling onto inside-screen
    pixels (or paint fill_color if internal_color is None). Outside
    pixels are transparent — other geometry composites through naturally.
    """
    out_w, out_h = view.width, view.height
    half_h = np.tan(view.fov_y_radians / 2)
    half_w_view = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, out_w) * half_w_view
    ys = np.linspace(1.0, -1.0, out_h) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)
    dirs_world = dirs_cam @ view.orientation.T

    origin = view.position
    eps = 1e-9
    safe_dz = np.where(np.abs(dirs_world[..., 2]) < eps,
                       eps * np.sign(dirs_world[..., 2] + eps),
                       dirs_world[..., 2])
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (t > 0) & (np.abs(x_hit) <= screen_w / 2.0) & (np.abs(y_hit) <= screen_h / 2.0)

    color_out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    depth_out = np.full((out_h, out_w), np.inf, dtype=np.float32)

    if internal_color is not None:
        internal_h, internal_w = internal_color.shape[:2]
        u = (x_hit + screen_w / 2.0) / screen_w
        v = 1.0 - (y_hit + screen_h / 2.0) / screen_h  # flip v so internal image isn't mirrored
        sample_x = np.clip((u * internal_w).astype(int), 0, internal_w - 1)
        sample_y = np.clip((v * internal_h).astype(int), 0, internal_h - 1)
        sampled = internal_color[sample_y, sample_x]
        color_out = np.where(inside[..., None], sampled, color_out)
    elif fill_color is not None:
        color_out[inside] = fill_color

    depth_out = np.where(inside, t.astype(np.float32), depth_out)
    return {"color": color_out, "depth": depth_out}
