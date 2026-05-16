"""
ProjectorN — renders an N-D sub-graph by projecting its verts/edges into
3D and rasterizing edges as line segments into the standard color/depth
channels.

The N-D primitives (DimensionN, future N-D node-types) emit named
channels carrying raw N-dimensional geometry. This renderer-node
consumes those channels, applies a projection, and produces ordinary
image channels for the default compositor.

Projection methods (v1):
- "drop"            — drop dimensions beyond 3 (orthogonal projection
                       onto the first 3 axes). Default; simple and
                       robust.
- "perspective_4d"  — for dims==4 only: perspective projection from a
                       4D viewpoint at distance `w_eye` looking along
                       +W onto a 3D hyperplane. The result is a 3D
                       shape whose perceived size changes with the
                       point's 4D-W coordinate, producing the classic
                       "rotating tesseract" inside-out effect when
                       combined with a 4D rotation.

Future projections drop into _project_4d_to_3d / _project_n_to_3d as
new branches; the renderer's emit contract stays stable.

A `rotation_nd` param accepts a list-of-lists N×N matrix to pre-rotate
the verts before projection — this is how dream-mode views rotate the
hypercube against the camera. Default identity.
"""

from __future__ import annotations

from typing import Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="ProjectorN",
        version="1.0",
        renderer_id="raster",
        inputs={"source": "nd_subgraph", "projection": "str",
                "w_eye": "float", "line_thickness": "int",
                "rotation_nd": "list_of_lists"},
        outputs={"color": "rgb_image", "depth": "depth_image", "ids": "id_image"},
        description=(
            "Renders an N-D sub-graph by projecting verts to 3D and "
            "rasterizing edges. Projection method selectable; default "
            "drops trailing dims."
        ),
    )


def build(params):
    return {
        "projection": str(params.get("projection", "drop")),
        "w_eye": float(params.get("w_eye", 3.0)),
        "line_thickness": int(params.get("line_thickness", 1)),
        "rotation_nd": params.get("rotation_nd"),
        "background_color": np.asarray(
            params.get("background_color", [0.05, 0.05, 0.08]),
            dtype=np.float32,
        ),
    }


def select_children(state, view: View, engine, node):
    """
    Recurse into the "source" sub-graph but only collect its N-D channel
    output. The engine's default compositor then runs on what _this_ node
    returns — we override compositing via our own emit().
    """
    return ["source"] if "source" in node.connections else []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    w, h = view.width, view.height
    color_img = np.zeros((h, w, 3), dtype=np.float32)
    color_img[:] = state["background_color"]
    depth_img = np.full((h, w), np.inf, dtype=np.float32)
    ids_img = np.zeros((h, w), dtype=np.uint32)

    src = ctx.child_outputs.get("source")
    if src is None:
        return {"color": color_img, "depth": depth_img, "ids": ids_img}

    _, src_channels = src
    verts_nd = src_channels.get("verts_nd")
    edges = src_channels.get("edges")
    if verts_nd is None or edges is None or len(verts_nd) == 0:
        return {"color": color_img, "depth": depth_img, "ids": ids_img}

    color = np.asarray(src_channels.get("nd_color", [1.0, 1.0, 1.0]), dtype=np.float32)
    node_id = int(src_channels.get("nd_node_id", 1))

    # Optionally pre-rotate in N-D before projecting.
    verts_rotated = _apply_rotation_nd(verts_nd, state.get("rotation_nd"))

    # Project to 3D.
    verts_3d = _project_to_3d(verts_rotated, state["projection"], state["w_eye"])

    # Project 3D verts through the camera to 2D image space.
    verts_2d, depths = _camera_project(verts_3d, view)

    # Rasterize edges as line segments.
    thickness = max(1, int(state["line_thickness"]))
    for (a, b) in edges:
        _draw_line(color_img, depth_img, ids_img,
                   verts_2d[a], depths[a],
                   verts_2d[b], depths[b],
                   color, node_id, thickness)

    return {"color": color_img, "depth": depth_img, "ids": ids_img}


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------


def _apply_rotation_nd(verts_nd: np.ndarray, rot) -> np.ndarray:
    if rot is None:
        return verts_nd
    rot = np.asarray(rot, dtype=np.float64)
    if rot.shape == (verts_nd.shape[1], verts_nd.shape[1]):
        return verts_nd @ rot.T
    return verts_nd


def _project_to_3d(verts_nd: np.ndarray, method: str, w_eye: float) -> np.ndarray:
    if verts_nd.shape[1] <= 3:
        # Pad with zeros if fewer than 3 dims.
        if verts_nd.shape[1] < 3:
            pad = np.zeros((verts_nd.shape[0], 3 - verts_nd.shape[1]))
            return np.hstack([verts_nd, pad])
        return verts_nd.copy()
    if method == "perspective_4d" and verts_nd.shape[1] == 4:
        w = verts_nd[:, 3]
        denom = (w_eye - w)
        denom = np.where(np.abs(denom) < 1e-6, 1e-6, denom)
        scale = w_eye / denom
        return verts_nd[:, :3] * scale[:, None]
    # Default "drop": take first three dims.
    return verts_nd[:, :3].copy()


def _camera_project(verts_3d: np.ndarray, view: View):
    """Project world-frame 3D verts through view's orientation/position
    into 2D image coordinates plus per-vert depth. Returns (verts_2d, depths)
    where verts_2d is (V, 2) in pixel coords and depths is (V,) in camera-z."""
    rel = verts_3d - view.position[None, :]
    cam = rel @ view.orientation  # world → camera basis
    z = -cam[:, 2]  # camera looks down -Z so positive z is "in front"

    half_h = np.tan(view.fov_y_radians / 2)
    half_w = half_h * view.aspect()
    z_safe = np.where(z <= 1e-6, 1e-6, z)
    x_ndc = cam[:, 0] / (z_safe * half_w)
    y_ndc = cam[:, 1] / (z_safe * half_h)
    px = (x_ndc * 0.5 + 0.5) * (view.width - 1)
    py = (0.5 - y_ndc * 0.5) * (view.height - 1)
    verts_2d = np.stack([px, py], axis=1)
    depths = np.where(z > 0, z, np.inf).astype(np.float32)
    return verts_2d, depths


def _draw_line(color_img, depth_img, ids_img,
               p0, d0, p1, d1, rgb, node_id, thickness):
    """Bresenham-ish line with linear depth interpolation."""
    if not np.all(np.isfinite([p0[0], p0[1], p1[0], p1[1], d0, d1])):
        return
    h, w = color_img.shape[:2]
    x0, y0 = int(round(p0[0])), int(round(p0[1]))
    x1, y1 = int(round(p1[0])), int(round(p1[1]))
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    for i in range(steps + 1):
        t = i / steps
        x = int(round(x0 + (x1 - x0) * t))
        y = int(round(y0 + (y1 - y0) * t))
        d = d0 + (d1 - d0) * t
        for dx in range(-(thickness // 2), thickness // 2 + 1):
            for dy in range(-(thickness // 2), thickness // 2 + 1):
                xx = x + dx
                yy = y + dy
                if 0 <= xx < w and 0 <= yy < h and d < depth_img[yy, xx]:
                    color_img[yy, xx] = rgb
                    depth_img[yy, xx] = d
                    ids_img[yy, xx] = node_id
