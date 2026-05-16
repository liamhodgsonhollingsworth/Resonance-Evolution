"""
Sphere — ray-cast against a sphere at the local origin; smooth-shaded by
the normal's projection onto the camera-forward direction. Same channel
contract as Cube (color + depth + ids). Demonstrates that geometric
primitives are independent files; new shapes add by writing a new file
without touching the engine.
"""

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Sphere",
        version="1.0",
        renderer_id="raster",
        inputs={"radius": "float", "color": "vec3"},
        outputs={"color": "rgb_image", "depth": "depth_image", "ids": "id_image"},
        description=(
            "A sphere at the local origin. Ray-cast emit with smooth "
            "shading from the surface normal."
        ),
    )


def build(params):
    return {
        "radius": float(params.get("radius", 1.0)),
        "color": np.asarray(params.get("color", [0.5, 0.7, 0.8]), dtype=np.float32),
        "node_id_hash": int(params.get("id_hash", 1)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    radius = state["radius"]
    base_color = state["color"]
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
    # Ray-sphere intersection (sphere at local origin)
    o_dot_d = (origin[None, None, :] * dirs_world).sum(axis=-1)
    o_dot_o = float(np.dot(origin, origin))
    disc = o_dot_d ** 2 - (o_dot_o - radius ** 2)
    has_disc = disc > 0
    sqrt_disc = np.sqrt(np.maximum(disc, 0.0))
    t_near = -o_dot_d - sqrt_disc
    hit = has_disc & (t_near > 0)

    depth = np.where(hit, t_near, np.inf).astype(np.float32)

    # Normal at hit point
    p_hit = origin[None, None, :] + t_near[..., None] * dirs_world
    normal = p_hit / radius

    camera_forward = view.orientation @ np.array([0.0, 0.0, -1.0])
    n_dot_f = (normal * camera_forward[None, None, :]).sum(axis=-1)
    shade = np.clip(-n_dot_f, 0.3, 1.0).astype(np.float32)

    color_img = np.zeros((h, w, 3), dtype=np.float32)
    color_img[hit] = (base_color[None, :] * shade[..., None])[hit]

    ids_img = np.where(hit, state["node_id_hash"], 0).astype(np.uint32)
    return {"color": color_img, "depth": depth, "ids": ids_img}


def describe(state, ctx: EmitContext) -> str:
    c = state["color"]
    return (f"Sphere id={ctx.node.id} radius={state['radius']:.2f} "
            f"color=[{c[0]:.2f}, {c[1]:.2f}, {c[2]:.2f}]")
