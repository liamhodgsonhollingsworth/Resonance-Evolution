"""
Aggregator — observes its 'target' sub-graph and dispatches between the
target's full emit (when the viewer is close) and a precomputed coarse-
scale impostor (when the viewer is far). Demonstrates three architectural
commitments simultaneously:

  - **Aggregator-as-node.** The aggregation rule is a first-class node-
    type. New emergence schemes — statistical, learned, ML-derived, ABM
    — become new aggregator-node files, not engine-core changes.

  - **Emergence-at-scale.** Authors write cell-level rules in leaf nodes
    (Cubes here); the aggregator computes the macro-scale impostor
    automatically. The dispatch (impostor vs. full target) is by
    viewer-relative scale — distance for v1; projected-pixel-size for
    a future version with the same interface.

  - **Precomputation moves heavy work to build time.** precompute_hook
    walks the target sub-graph and stashes centroid + bounding-box +
    average-color in engine.cache. select_children() then SKIPS the
    target's runtime emit entirely when the impostor is in use — so
    the engine doesn't render-then-throw-away. The architectural
    commitment is real, not aspirational.

The cache entry doubles as a BehaviorSummary (centroid, extent, color,
leaf_count) that future nodes can query — physics, constraints, or
other aggregators reading collective state. v1 doesn't have consumers
yet, but the data is exposed.

The inline AABB rendering for the impostor is v1 expedient (~30 LOC).
v2 can factor it into its own Impostor node-type that this Aggregator
spawns at precompute time; Aggregator's interface (precompute_hook
signature, cache shape, select_children, emit) stays identical across
that refactor.
"""

import numpy as np
from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Aggregator",
        version="1.0",
        renderer_id="raster",
        inputs={
            "distance_threshold": "float",
            "aggregate_color": "vec3",
            "padding": "float",
        },
        outputs={
            "color": "rgb_image",
            "depth": "depth_image",
            "behavior_summary": "dict",
        },
        description=(
            "Wraps a 'target' sub-graph; precomputes centroid/bbox/color; "
            "dispatches between coarse-scale impostor (far) and target's "
            "full emit (near) based on viewer distance. Demonstrates "
            "aggregator-as-node + emergence-at-scale + precomputation-"
            "moves-heavy-work-to-build-time in one node-type."
        ),
    )


def build(params):
    return {
        "distance_threshold": float(params.get("distance_threshold", 10.0)),
        "aggregate_color": (
            np.asarray(params["aggregate_color"], dtype=np.float32)
            if "aggregate_color" in params
            else None  # None means use the precomputed average color
        ),
        "padding": float(params.get("padding", 0.5)),
    }


# ---------------------------------------------------------------------------
# Precompute: walk the target sub-graph, compute the BehaviorSummary
# ---------------------------------------------------------------------------

def precompute_hook(state, engine, node) -> Dict[str, Any]:
    target_conn = node.connections.get("target")
    if target_conn is None:
        return _empty_summary()
    target_id = _resolve_target(target_conn)

    positions: List[np.ndarray] = []
    colors: List[np.ndarray] = []
    half_sizes: List[float] = []
    _walk(engine, target_id, np.zeros(3, dtype=np.float64),
          positions, colors, half_sizes, depth_limit=12)

    if not positions:
        return _empty_summary()

    pos_arr = np.stack(positions, axis=0)
    color_arr = np.stack(colors, axis=0)
    centroid = pos_arr.mean(axis=0).astype(np.float32)
    extent = (pos_arr.max(axis=0) - pos_arr.min(axis=0)).astype(np.float32)
    # Pad by 2 * max half-size so the AABB encloses cube edges, not just centers
    max_half = max(half_sizes) if half_sizes else 0.5
    bounding_box = (extent + 2.0 * max_half + state["padding"]).astype(np.float32)
    avg_color = color_arr.mean(axis=0).astype(np.float32)

    return {
        "centroid": centroid,
        "bounding_box": bounding_box,
        "average_color": avg_color,
        "leaf_count": int(len(positions)),
    }


# ---------------------------------------------------------------------------
# select_children: skip the target's runtime emit when impostor is in use
# ---------------------------------------------------------------------------

def select_children(state, view: View, engine, node) -> List[str]:
    cache = engine.cache.get(node.id)
    if cache is None or cache.get("leaf_count", 0) == 0:
        return list(node.connections.keys())
    centroid = cache["centroid"].astype(np.float64)
    distance = float(np.linalg.norm(view.position - centroid))
    if distance > state["distance_threshold"]:
        return []  # impostor will be used; don't bother rendering the target
    return ["target"] if "target" in node.connections else list(node.connections.keys())


# ---------------------------------------------------------------------------
# emit: dispatch on distance
# ---------------------------------------------------------------------------

def emit(state, view: View, ctx: EmitContext) -> Channels:
    cache = ctx.engine.cache.get(ctx.node.id)
    if cache is None or cache.get("leaf_count", 0) == 0:
        through = ctx.child_outputs.get("target")
        if through is not None:
            return through[1]
        return _empty_channels(view)

    centroid = cache["centroid"].astype(np.float64)
    distance = float(np.linalg.norm(view.position - centroid))

    if distance > state["distance_threshold"]:
        # Far — render impostor (target's full emit was skipped via select_children)
        color = (state["aggregate_color"]
                 if state["aggregate_color"] is not None
                 else cache["average_color"])
        out = _render_impostor_aabb(
            view=view,
            centroid=centroid,
            half_size=cache["bounding_box"].astype(np.float64) / 2.0,
            color=np.asarray(color, dtype=np.float32),
        )
        out["behavior_summary"] = cache
        return out

    # Near — return the target's full emit, attach the BehaviorSummary
    through = ctx.child_outputs.get("target")
    if through is not None:
        return {**through[1], "behavior_summary": cache}
    return _empty_channels(view)


def describe(state, ctx: EmitContext) -> str:
    cache = ctx.engine.cache.get(ctx.node.id, {})
    return (f"Aggregator id={ctx.node.id} "
            f"threshold={state['distance_threshold']:.2f} "
            f"leaves={cache.get('leaf_count', '?')}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _empty_summary() -> Dict[str, Any]:
    return {
        "centroid": np.zeros(3, dtype=np.float32),
        "bounding_box": np.zeros(3, dtype=np.float32),
        "average_color": np.array([0.5, 0.5, 0.5], dtype=np.float32),
        "leaf_count": 0,
    }


def _walk(engine, node_id, accum_pos, positions, colors, half_sizes, depth_limit):
    if depth_limit <= 0:
        return
    node = engine.nodes.get(node_id)
    if node is None or node.dead:
        return
    if node.type_name == "Cube" and isinstance(node.state, dict):
        positions.append(accum_pos.copy())
        c = node.state.get("color")
        colors.append(np.asarray(c if c is not None else [0.5, 0.5, 0.5],
                                 dtype=np.float32))
        half_sizes.append(0.5 * float(node.state.get("size", 1.0)))
        return
    for _, conn in node.connections.items():
        target_id, transform = _resolve_connection(conn)
        child_pos = accum_pos.copy()
        if transform is not None:
            child_pos = child_pos + transform[:3, 3]
        _walk(engine, target_id, child_pos, positions, colors, half_sizes, depth_limit - 1)


def _resolve_connection(conn):
    if isinstance(conn, str):
        return conn, None
    if isinstance(conn, dict):
        tf = conn.get("transform")
        return conn["target"], np.asarray(tf, dtype=np.float64) if tf is not None else None
    if isinstance(conn, list):
        return conn[0], (np.asarray(conn[1], dtype=np.float64) if len(conn) > 1 else None)
    raise ValueError(f"unrecognized connection: {conn!r}")


def _resolve_target(conn):
    return _resolve_connection(conn)[0]


def _render_impostor_aabb(view: View, centroid, half_size, color) -> Channels:
    """Ray-cast against an AABB at centroid; same math as Cube with non-origin AABB."""
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
    box_min = centroid - half_size
    box_max = centroid + half_size
    eps = 1e-9
    safe = np.where(np.abs(dirs_world) < eps, eps * np.sign(dirs_world + eps), dirs_world)
    inv = 1.0 / safe
    t_a = (box_min - origin) * inv
    t_b = (box_max - origin) * inv
    t_low = np.minimum(t_a, t_b)
    t_high = np.maximum(t_a, t_b)
    t_near = np.max(t_low, axis=-1)
    t_far = np.min(t_high, axis=-1)
    hit = (t_near <= t_far) & (t_far > 0.0)

    depth = np.where(hit, np.maximum(t_near, 0.0), np.inf).astype(np.float32)
    color_img = np.zeros((h, w, 3), dtype=np.float32)
    dominant = np.argmax(t_low, axis=-1)
    shade = np.where(dominant == 0, 0.85,
                     np.where(dominant == 1, 1.0, 0.7)).astype(np.float32)
    color_img[hit] = (color[None, :] * shade[..., None])[hit]
    return {"color": color_img, "depth": depth}


def _empty_channels(view: View) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }
