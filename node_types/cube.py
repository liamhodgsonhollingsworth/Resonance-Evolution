"""
Cube — an axis-aligned cube centered at the node's origin. The minimal
demonstration of a leaf node-type with both visual emit() (ray-cast
against AABB) and text describe() (for the text-renderer).

Params:
    size  (float, default 1.0)  — edge length
    color (list of 3 floats, default [0.8, 0.5, 0.3]) — RGB in [0,1]
"""

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Cube",
        version="1.0",
        renderer_id="raster",
        inputs={"size": "float", "color": "vec3"},
        outputs={"color": "rgb_image", "depth": "depth_image", "ids": "id_image"},
        description="An axis-aligned cube. Demonstrates leaf node-types with ray-cast emit and text describe.",
    )


def build(params):
    return {
        "size": float(params.get("size", 1.0)),
        "color": np.asarray(params.get("color", [0.8, 0.5, 0.3]), dtype=np.float32),
        "node_id_hash": params.get("id_hash", 1),  # used for the IDs channel
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """
    Ray-cast against an axis-aligned cube of edge length state['size']
    centered at the local origin. Returns color, depth, and ids channels.

    The cube is in the local frame; view.position is the camera in that
    same local frame (the engine has already applied connection transforms
    before calling).
    """
    size = state["size"]
    color = state["color"]
    width, height = view.width, view.height

    # Pixel-space directions (camera frame). Camera looks down -Z by default.
    half_h = np.tan(view.fov_y_radians / 2)
    half_w = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, width) * half_w
    ys = np.linspace(1.0, -1.0, height) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)

    # Rotate into world space (view.orientation maps camera frame -> world frame)
    dirs_world = dirs_cam @ view.orientation.T

    # Ray origin in world frame
    origin = view.position

    # Ray-vs-AABB: cube centered at origin, edge `size`
    half = size / 2.0
    box_min = np.array([-half, -half, -half], dtype=np.float64)
    box_max = np.array([half, half, half], dtype=np.float64)

    # Avoid division by zero; clamp small dirs
    eps = 1e-9
    safe_dirs = np.where(np.abs(dirs_world) < eps, eps * np.sign(dirs_world + eps), dirs_world)
    inv = 1.0 / safe_dirs

    t_a = (box_min - origin) * inv
    t_b = (box_max - origin) * inv
    t_low = np.minimum(t_a, t_b)
    t_high = np.maximum(t_a, t_b)
    t_near = np.max(t_low, axis=-1)
    t_far = np.min(t_high, axis=-1)
    hit = (t_near <= t_far) & (t_far > 0.0)

    depth = np.where(hit, np.maximum(t_near, 0.0), np.inf).astype(np.float32)

    color_img = np.zeros((height, width, 3), dtype=np.float32)
    # Lambertian-ish shading: shade slightly based on the dominant hit face normal.
    # Compute approximate face normal from which slab dominates t_near.
    t_low_a, t_low_b, t_low_c = t_low[..., 0], t_low[..., 1], t_low[..., 2]
    dominant_axis = np.argmax(t_low, axis=-1)
    shade = np.where(
        dominant_axis == 0, 0.85,
        np.where(dominant_axis == 1, 1.0, 0.7)
    ).astype(np.float32)
    color_img[hit] = (color[None, :] * shade[..., None])[hit]

    ids_img = np.where(hit, state["node_id_hash"], 0).astype(np.uint32)

    return {"color": color_img, "depth": depth, "ids": ids_img}


def describe(state, ctx: EmitContext) -> str:
    """Text description for the text-renderer."""
    color = state["color"]
    return (
        f"Cube id={ctx.node.id} size={state['size']:.2f} "
        f"color=[{color[0]:.2f}, {color[1]:.2f}, {color[2]:.2f}]"
    )
