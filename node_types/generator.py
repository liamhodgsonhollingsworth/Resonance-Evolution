"""
Generator — turns a Seed's parameters into content.

A Generator's `seed` connection points at a Seed node. The Generator's
precompute_hook reads the seed's parameters and computes a content spec
(in v1, a list of cube positions/colors). Its emit() rasterizes the spec
inline so the visual demo composes end-to-end.

The architectural commitment is in invert_hook(state, edit, engine, node).
When the engine's invert_edit() walk lands on this Generator, the hook
receives an edit description (e.g. "cube index 2 should be at [5,0,0]")
and returns a parameter delta to apply to the connected Seed. The delta
is applied, the Generator's precompute_hook re-runs, and the content
updates as if the seed had always produced the new arrangement.

v1's invert is a trivial pass-through: it expects an edit of shape
    {"target": "cube_position", "index": int, "new_value": [x,y,z]}
and returns a seed delta that directly updates the corresponding position
in the seed's `cube_positions` parameter. A future, more interesting
invert tunes higher-level parameters (spread, density, color_seed)
by gradient over (param → output); v1 demonstrates the dispatch flow.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Generator",
        version="1.0",
        renderer_id="raster",
        inputs={"seed": "Seed (connection)"},
        outputs={"color": "rgb_image", "depth": "depth_image", "ids": "id_image"},
        description=(
            "Consumes a Seed via the 'seed' connection; produces content "
            "(v1: cube positions and colors). Exposes invert_hook so a "
            "viewer edit on generated content updates the Seed."
        ),
    )


def build(params):
    return {
        "node_id_hash": int(params.get("id_hash", 13)),
        "fallback_color": np.asarray(
            params.get("fallback_color", [0.6, 0.6, 0.6]),
            dtype=np.float32,
        ),
        "cube_size": float(params.get("cube_size", 0.4)),
    }


def precompute_hook(state, engine, node):
    """
    Read the connected Seed; produce a content spec.

    v1 spec is a list of {"position": [x,y,z], "color": [r,g,b], "size": s}
    derived from seed["params"]["cube_positions"] and other knobs.
    Stored in engine.cache[node.id]["specs"]. The Generator's emit reads
    from this cache.
    """
    seed_state = _read_seed_state(engine, node)
    if seed_state is None:
        return {"specs": []}

    sp = seed_state.get("params", {})
    positions: List[List[float]] = sp.get("cube_positions", [[0, 0, 0]])
    base_color = sp.get("color", [0.7, 0.8, 0.5])
    size = float(sp.get("cube_size", state["cube_size"]))

    rng = np.random.default_rng(seed_state["rng_seed"])
    specs = []
    for i, p in enumerate(positions):
        c = np.asarray(base_color, dtype=np.float32) * (0.5 + 0.5 * rng.random())
        specs.append({
            "position": np.asarray(p, dtype=np.float32),
            "color": np.clip(c, 0.0, 1.0),
            "size": size,
        })
    return {"specs": specs}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """
    Inline-rasterize the precomputed specs as axis-aligned boxes. Mirrors
    Cube.emit's ray-cast loop but operates on multiple bounding boxes at
    once.
    """
    w, h = view.width, view.height
    color_img = np.zeros((h, w, 3), dtype=np.float32)
    depth_img = np.full((h, w), np.inf, dtype=np.float32)
    ids_img = np.zeros((h, w), dtype=np.uint32)

    cache_entry = ctx.engine.cache.get(ctx.node.id, {})
    specs = cache_entry.get("specs", [])
    if not specs:
        return {"color": color_img, "depth": depth_img, "ids": ids_img}

    # Set up the ray bundle once.
    half_h = np.tan(view.fov_y_radians / 2)
    half_w = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, w) * half_w
    ys = np.linspace(1.0, -1.0, h) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)
    dirs_world = dirs_cam @ view.orientation.T
    origin = view.position

    for i, spec in enumerate(specs):
        p = spec["position"]
        s = float(spec["size"])
        # Slab method against an AABB centered at p with half-extent s.
        inv = 1.0 / np.where(np.abs(dirs_world) < 1e-9, 1e-9, dirs_world)
        t1 = (p[None, None, :] - s - origin[None, None, :]) * inv
        t2 = (p[None, None, :] + s - origin[None, None, :]) * inv
        t_min = np.minimum(t1, t2).max(axis=-1)
        t_max = np.maximum(t1, t2).min(axis=-1)
        hit = (t_min <= t_max) & (t_min > 0)
        depth = np.where(hit, t_min, np.inf).astype(np.float32)
        winner = depth < depth_img
        color_img = np.where(winner[..., None], spec["color"][None, None, :], color_img)
        depth_img = np.where(winner, depth, depth_img)
        ids_img = np.where(winner, state["node_id_hash"] * 1000 + i, ids_img).astype(np.uint32)

    return {"color": color_img, "depth": depth_img, "ids": ids_img}


def describe(state, ctx: EmitContext) -> str:
    specs = ctx.engine.cache.get(ctx.node.id, {}).get("specs", [])
    return f"Generator id={ctx.node.id} produced {len(specs)} cubes"


def invert_hook(state, edit: Dict[str, Any], engine, node) -> Optional[Dict[str, Any]]:
    """
    Translate a content edit into a seed parameter delta.

    v1 supported edit:
        {"target": "cube_position", "index": int, "new_value": [x,y,z]}
    returning delta:
        {"params": <updated params dict>}
    """
    target = edit.get("target")
    if target != "cube_position":
        return None
    idx = int(edit.get("index", -1))
    new_value = edit.get("new_value")
    if idx < 0 or new_value is None:
        return None

    seed_state = _read_seed_state(engine, node)
    if seed_state is None:
        return None
    params = dict(seed_state.get("params", {}))
    positions = list(params.get("cube_positions", []))
    while len(positions) <= idx:
        positions.append([0.0, 0.0, 0.0])
    positions[idx] = list(new_value)
    params["cube_positions"] = positions
    return {"params": params}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _read_seed_state(engine, node):
    conn = node.connections.get("seed")
    if conn is None:
        return None
    seed_id = conn if isinstance(conn, str) else conn.get("target")
    seed = engine.nodes.get(seed_id)
    if seed is None or seed.dead:
        return None
    return seed.state
