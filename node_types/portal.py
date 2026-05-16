"""
Portal — a rectangular doorway whose far side is connected to another
graph region via a non-identity transform on its "through" connection.

Demonstrates the topology-over-coordinates architectural commitment.
The engine already applies the connection's 4x4 transform when recursing
into the target sub-graph; Portal.emit() does the rectangle-mask
compositing on top of that automatic transform handling. No new engine
primitive is needed — impossible geometries are a node-type, not an
engine feature.

The doorway is a rectangle in the XY plane at z=0 in the portal's local
frame, facing +Z. The portal is "looked at" by a camera with positive z
in its local frame; rays hitting inside the doorway show the "through"
connection's content (already rendered under the transformed view).

A scene that uses Portal:
- Wraps a Portal node in some parent.
- Gives the Portal a "through" connection whose target is the node
  visible on the other side and whose 4x4 transform is the relative pose
  of the target's frame within the portal's frame.

Identity transform on the "through" connection makes the portal a
"window" showing whatever's at the same coordinates in another sub-graph.
Non-identity transforms enable wrapping, gravity-shifts, teleporters,
hyperbolic adjacency, and any other impossible-geometry move that maps
to a 4x4 transform.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Portal",
        version="1.0",
        renderer_id="raster",
        inputs={"width": "float", "height": "float"},
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "A rectangular doorway whose 'through' connection's transform "
            "places the far-side graph region at any pose. Demonstrates "
            "topology-over-coordinates: impossible geometries are nodes, "
            "not engine features."
        ),
    )


def build(params):
    return {
        "width": float(params.get("width", 2.0)),
        "height": float(params.get("height", 3.0)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """
    Ray-cast against the doorway rectangle in the XY plane at z=0. For
    pixels inside the doorway, use the "through" child's color (already
    rendered by the engine under the transformed view). For pixels
    outside, return inf depth so other scene geometry composites in.

    The portal's depth at inside pixels is the distance to the doorway
    plane in the parent's frame — this keeps the Z-buffer compositor
    coherent. Things in front of the portal in the parent scene occlude
    it; things behind it are occluded by the portal itself, which is
    correct (you don't see "around" the portal from in front of it).
    """
    out_w, out_h = view.width, view.height
    door_w, door_h = state["width"], state["height"]

    # Pixel-space rays in camera frame, then rotated to world (portal's local) frame.
    half_h = np.tan(view.fov_y_radians / 2)
    half_w = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, out_w) * half_w
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
    # Ray hits z=0 plane when origin.z + t * dir.z = 0
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (t > 0) & (np.abs(x_hit) <= door_w / 2) & (np.abs(y_hit) <= door_h / 2)

    color_out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    depth_out = np.full((out_h, out_w), np.inf, dtype=np.float32)

    through = ctx.child_outputs.get("through")
    if through is not None:
        _, child_channels = through
        child_color = child_channels.get("color")
        if child_color is not None and child_color.shape[:2] == (out_h, out_w):
            color_out = np.where(inside[..., None], child_color, color_out)

    depth_out = np.where(inside, t.astype(np.float32), depth_out)

    return {"color": color_out, "depth": depth_out}


def describe(state, ctx: EmitContext) -> str:
    target = ctx.node.connections.get("through")
    target_id = (target if isinstance(target, str)
                 else target.get("target") if isinstance(target, dict)
                 else target[0] if isinstance(target, list) else "(none)")
    return (f"Portal id={ctx.node.id} doorway={state['width']:.2f}x{state['height']:.2f} "
            f"through={target_id}")
