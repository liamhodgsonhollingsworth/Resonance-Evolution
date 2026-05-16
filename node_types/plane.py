"""
Plane — a bounded plane in the local XZ plane at y=0 (floor orientation:
normal points +Y). Same channel contract as Cube and Sphere (color +
depth + ids + normal). For walls or ceilings, use a connection transform
to rotate the plane's local frame.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Plane",
        version="1.0",
        renderer_id="raster",
        inputs={"size_x": "float", "size_z": "float", "color": "vec3"},
        outputs={"color": "rgb_image", "depth": "depth_image",
                 "ids": "id_image", "normal": "vec3_image"},
        description=(
            "A bounded floor plane in local XZ at y=0; normal +Y. "
            "Walls and ceilings via connection transform rotations."
        ),
    )


def build(params):
    return {
        "size_x": float(params.get("size_x", 10.0)),
        "size_z": float(params.get("size_z", 10.0)),
        "color": np.asarray(params.get("color", [0.45, 0.45, 0.50]), dtype=np.float32),
        "node_id_hash": int(params.get("id_hash", 1)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    size_x = state["size_x"]
    size_z = state["size_z"]
    color = state["color"]
    w, h = view.width, view.height

    half_h = np.tan(view.fov_y_radians / 2)
    half_w = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, w) * half_w
    ys = np.linspace(1.0, -1.0, h) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)
    dirs_world = dirs_cam @ view.orientation.T

    origin = view.position
    eps = 1e-9
    safe_dy = np.where(np.abs(dirs_world[..., 1]) < eps,
                       eps * np.sign(dirs_world[..., 1] + eps),
                       dirs_world[..., 1])
    t = -origin[1] / safe_dy
    x_hit = origin[0] + t * dirs_world[..., 0]
    z_hit = origin[2] + t * dirs_world[..., 2]
    inside = (t > 0) & (np.abs(x_hit) <= size_x / 2.0) & (np.abs(z_hit) <= size_z / 2.0)

    depth = np.where(inside, t.astype(np.float32), np.inf).astype(np.float32)
    color_img = np.zeros((h, w, 3), dtype=np.float32)
    color_img[inside] = color
    ids_img = np.where(inside, state["node_id_hash"], 0).astype(np.uint32)
    normals = np.zeros((h, w, 3), dtype=np.float32)
    normals[inside, 1] = 1.0
    return {"color": color_img, "depth": depth, "ids": ids_img, "normal": normals}


def describe(state, ctx: EmitContext) -> str:
    return f"Plane id={ctx.node.id} size={state['size_x']:.1f}x{state['size_z']:.1f}"
