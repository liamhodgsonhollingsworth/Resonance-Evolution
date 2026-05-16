"""
DimensionN — an N-dimensional geometric primitive.

State carries vertices in N-D space plus an edge list. Emit produces
named channels `verts_nd` (shape: (V, N)) and `edges` (shape: (E, 2),
integer index pairs into verts_nd), which a downstream renderer (typically
ProjectorN) consumes and projects down into the 3D channels expected by
the standard compositor.

This node-type does not itself render anything; it is a content node
whose output is consumed by a renderer-node. That separation is the
architecture's commitment: the projection algorithm is a renderer choice,
not a geometry choice. Different ProjectorN configurations can render the
same DimensionN content via stereographic projection, parallel projection,
slice-and-cap, or any future scheme.

Supported shapes (v1): "hypercube" (all combinations of ±1 in N dims).
Future: "simplex", "cross_polytope", "hypersphere", and shape:"custom" with
caller-provided vertices.
"""

from __future__ import annotations

import itertools

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="DimensionN",
        version="1.0",
        renderer_id="projector_n",
        inputs={"dims": "int", "shape": "str", "size": "float", "color": "vec3"},
        outputs={"verts_nd": "ndarray(V,N)", "edges": "ndarray(E,2)"},
        description=(
            "An N-dimensional shape. Emits raw N-D vertices and edges for "
            "a downstream projector renderer to render. v1 ships hypercube; "
            "additional shapes added as new shape:* params."
        ),
    )


def build(params):
    dims = int(params.get("dims", 4))
    shape = str(params.get("shape", "hypercube"))
    size = float(params.get("size", 1.0))
    color = np.asarray(params.get("color", [0.7, 0.8, 1.0]), dtype=np.float32)

    verts, edges = _build_shape(shape, dims, size)
    return {
        "dims": dims,
        "shape": shape,
        "size": size,
        "color": color,
        "verts_nd": verts,
        "edges": edges,
        "node_id_hash": int(params.get("id_hash", 7)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """
    Pass the N-D verts and edges through as channels. No rasterization —
    the projector consumes them and produces image channels.
    """
    return {
        "verts_nd": state["verts_nd"],
        "edges": state["edges"],
        "nd_color": state["color"],
        "nd_dims": state["dims"],
        "nd_node_id": state["node_id_hash"],
    }


def describe(state, ctx: EmitContext) -> str:
    return (f"DimensionN id={ctx.node.id} shape={state['shape']} "
            f"dims={state['dims']} verts={len(state['verts_nd'])} "
            f"edges={len(state['edges'])}")


# ---------------------------------------------------------------------------
# Shape constructors. Each returns (verts_nd, edges).
# ---------------------------------------------------------------------------


def _build_shape(shape: str, dims: int, size: float):
    if shape == "hypercube":
        return _hypercube(dims, size)
    if shape == "simplex":
        return _simplex(dims, size)
    if shape == "cross_polytope":
        return _cross_polytope(dims, size)
    # Unknown shape: return empty placeholder; engine isolation prevents
    # downstream crashes.
    return (np.zeros((0, max(dims, 1)), dtype=np.float64),
            np.zeros((0, 2), dtype=np.int32))


def _hypercube(dims: int, size: float):
    """All 2^dims corners; edges connect corners that differ in exactly one
    coordinate. For dims=4 returns 16 vertices and 32 edges (tesseract)."""
    if dims < 1:
        return (np.zeros((0, 1), dtype=np.float64),
                np.zeros((0, 2), dtype=np.int32))
    coords = list(itertools.product([-1.0, 1.0], repeat=dims))
    verts = np.asarray(coords, dtype=np.float64) * size
    edges = []
    for i in range(len(verts)):
        for j in range(i + 1, len(verts)):
            if np.sum(np.abs(verts[i] - verts[j]) > 1e-9) == 1:
                edges.append((i, j))
    return verts, np.asarray(edges, dtype=np.int32)


def _simplex(dims: int, size: float):
    """N-simplex: N+1 vertices, all pairs connected. Uses the standard
    embedding in N+1 dims projected down to N. For dims=3 this is a
    tetrahedron."""
    if dims < 1:
        return (np.zeros((0, 1), dtype=np.float64),
                np.zeros((0, 2), dtype=np.int32))
    n = dims + 1
    # Place N+1 vertices at the standard basis of R^(N+1), then
    # subtract the centroid and project into R^N via an orthogonal frame.
    raw = np.eye(n)
    centered = raw - raw.mean(axis=0, keepdims=True)
    # Orthonormal basis of the (N+1-1)-dim hyperplane through centered.
    u, _, _ = np.linalg.svd(centered.T, full_matrices=False)
    verts = (centered @ u)[:, :dims] * size
    edges = [(i, j) for i in range(n) for j in range(i + 1, n)]
    return verts, np.asarray(edges, dtype=np.int32)


def _cross_polytope(dims: int, size: float):
    """N-cross-polytope: 2N vertices on the coordinate axes; edges connect
    every pair NOT on the same axis. For dims=3 this is an octahedron."""
    if dims < 1:
        return (np.zeros((0, 1), dtype=np.float64),
                np.zeros((0, 2), dtype=np.int32))
    verts = np.zeros((2 * dims, dims), dtype=np.float64)
    for i in range(dims):
        verts[2 * i, i] = size
        verts[2 * i + 1, i] = -size
    edges = []
    for i in range(2 * dims):
        for j in range(i + 1, 2 * dims):
            if i // 2 != j // 2:
                edges.append((i, j))
    return verts, np.asarray(edges, dtype=np.int32)
