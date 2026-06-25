"""Character genome resolver — a FLAME-style parametric head → GLB with morph targets.

This is Character Increment A's "one new piece of real code" (see
notes/research/character_genome_integration_plan_2026-06-25.md §2 in the Wavelet repo):
a renderer-NEUTRAL resolver that turns a *parameter vector* (the genome) into geometry and
writes a GLB with morph targets, plus the `scene_node` descriptor that rides the already-shipped
`mesh.source` seam (prim_model.gd / GodotSceneRenderer.build_node) as `mesh.source="character"`.

A character genome is a flat coefficient vector in a linear PCA space, exactly as FLAME 2023 Open
exposes (identity βs + expression ψs + pose). The resolve is pure linear algebra:

    vertices = mean + Σ_i  identity[i] · identity_basis[i]   (+ a `stylize_delta` proportion push)
    morph_target_j = Σ_i expression[i] · expression_basis[i, j]   (per-expression vertex deltas)

so crossover/mutation of the vector ALWAYS yields a valid face (the key advantage of a parametric
base — see the research memo §3). Realism vs the Arcane "boil-down" is one extra scalar:

    stylize_amount ∈ [0,1]   — 0 = realistic (raw genome), 1 = arcane (proportion-exaggerated)

applied as a FIXED `stylize_delta` along named semantic PCA axes (eyes ↑, jaw ↓, cranium ↑, nose ↓).
BOTH amounts produce valid GLBs — no remodeling, just a coefficient transform (research memo §1-2).

FLAME WEIGHTS — licensing/gating (read this before "fixing" the basis):
  FLAME 2023 Open is CC-BY-4.0 (commercial + derivative + algorithmic use OK with attribution), but
  its download sits behind a registration form. This module therefore ships with a SMALL SYNTHETIC
  PCA basis (deterministic, seeded) so the ENTIRE pipeline is proven end-to-end with zero account /
  zero login. The synthetic basis is a drop-in for real weights: replace `SyntheticFlameBasis` with a
  loader that reads the real FLAME `.npz` (mean + shapedirs + expdirs) into the SAME arrays — NO other
  code changes. See `load_basis()` and README at the foot of this file for the exact swap + the URL
  Liam must visit to fetch the real weights.

CLI (headless, deterministic):
    py tools/character_resolver.py --identity 1.0 -0.5 0.7 --expression 0.3 0.0 \
        --stylize-amount 1.0 --out face.glb --emit-scene-node face.scene_node.json

Pure stdlib + numpy. The GLB writer is a tiny self-contained glTF-2.0 binary emitter (no pygltflib),
so the only dependency is numpy for the linear algebra.
"""

from __future__ import annotations

import argparse
import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

# glTF component / accessor constants (spec) — kept local so there is no glTF dependency.
_FLOAT = 5126
_UINT = 5125
_ARRAY_BUFFER = 34962
_ELEMENT_ARRAY_BUFFER = 34963
_TRIANGLES = 4

# Named semantic axes the `stylize_delta` pushes along, as (identity-coefficient-index, weight).
# Index i means "PCA identity direction i is semantically ~this feature" — for the synthetic basis
# we DEFINE the first axes to be these features so the delta is interpretable; for real FLAME the
# mapping is fit once offline (research memo §2) and dropped in here unchanged.
STYLIZE_AXES = {
    "eyes_larger": (0, +1.6),    # bigger eyes  → push axis 0 up
    "jaw_narrower": (1, -1.4),   # narrower jaw → push axis 1 down
    "cranium_larger": (2, +1.1), # larger cranium
    "nose_smaller": (3, -0.9),   # smaller nose
}


@dataclass
class CharacterBasis:
    """A linear morphable-head basis: mean mesh + identity directions + expression directions.

    All arrays are renderer-neutral float data. This is the SINGLE seam real FLAME weights swap into
    (same shapes), so nothing downstream knows whether the basis is synthetic or the real model.
    """

    mean: np.ndarray            # (V, 3) neutral mesh vertices
    faces: np.ndarray           # (F, 3) triangle indices (uint)
    identity_dirs: np.ndarray   # (Ki, V, 3) identity PCA directions (β basis)
    expression_dirs: np.ndarray # (Ke, V, 3) expression PCA directions (ψ basis) → morph targets
    source: str                 # "synthetic" | "flame-2023-open" (provenance, written into the genome)

    @property
    def n_vertices(self) -> int:
        return int(self.mean.shape[0])


def _uv_sphere(n_lat: int = 24, n_lon: int = 32, radius: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """A deterministic UV-sphere mesh used as the synthetic head's base topology (stands in for the
    FLAME 5023-vert head). Returns (vertices (V,3), faces (F,3) uint32). A real swap replaces this with
    FLAME's fixed topology — only the data changes, not the pipeline."""
    verts: list[list[float]] = []
    for i in range(n_lat + 1):
        theta = np.pi * i / n_lat            # 0..π  (pole to pole)
        for j in range(n_lon):
            phi = 2.0 * np.pi * j / n_lon     # 0..2π
            verts.append([
                radius * np.sin(theta) * np.cos(phi),
                radius * np.cos(theta),
                radius * np.sin(theta) * np.sin(phi),
            ])
    faces: list[list[int]] = []
    for i in range(n_lat):
        for j in range(n_lon):
            a = i * n_lon + j
            b = i * n_lon + (j + 1) % n_lon
            c = (i + 1) * n_lon + j
            d = (i + 1) * n_lon + (j + 1) % n_lon
            faces.append([a, c, b])
            faces.append([b, c, d])
    return np.asarray(verts, dtype=np.float32), np.asarray(faces, dtype=np.uint32)


class SyntheticFlameBasis:
    """Deterministic synthetic stand-in for the FLAME 2023 Open basis (mean + identity + expression
    PCA directions). Seeded → reproducible. The first identity directions are DEFINED to be the
    semantic axes in STYLIZE_AXES so the `stylize_delta` is interpretable; the rest are smooth random
    low-frequency fields so different coefficient vectors give visibly different, coherent faces."""

    @staticmethod
    def build(n_identity: int = 8, n_expression: int = 4, seed: int = 20260625) -> CharacterBasis:
        mean, faces = _uv_sphere()
        v = mean.shape[0]
        rng = np.random.default_rng(seed)

        # Identity directions: the first 4 are explicit, interpretable feature pushes (so STYLIZE_AXES
        # means something); the rest are smooth random deformations. Each is unit-normalized so a
        # coefficient of 1.0 is a comparable-magnitude edit across axes.
        identity = np.zeros((n_identity, v, 3), dtype=np.float32)
        y = mean[:, 1]  # vertical axis (pole = head top)
        x = mean[:, 0]
        z = mean[:, 2]
        # axis 0 "eyes_larger": local bulge on the front upper face (z>0, y in mid-upper band)
        front_upper = (z > 0.2) & (y > 0.0) & (y < 0.8)
        identity[0][front_upper] += np.stack([x, y, z], axis=1)[front_upper] * 0.5
        # axis 1 "jaw_narrower": squeeze x near the bottom (y<0)
        lower = y < -0.2
        identity[1][lower, 0] += -x[lower] * 0.6
        # axis 2 "cranium_larger": expand top (y>0.4) outward
        top = y > 0.4
        identity[2][top] += np.stack([x, y, z], axis=1)[top] * 0.4
        # axis 3 "nose_smaller": pull the front-center point inward (z>0, |x| small, mid y)
        nose = (z > 0.5) & (np.abs(x) < 0.3) & (np.abs(y) < 0.3)
        identity[3][nose, 2] += -z[nose] * 0.5
        # remaining axes: smooth low-frequency random fields (coherent, not noise spikes)
        for k in range(4, n_identity):
            freq = rng.uniform(0.5, 2.0, size=3)
            phase = rng.uniform(0, 2 * np.pi, size=3)
            field = np.stack([
                np.sin(freq[0] * x + phase[0]),
                np.sin(freq[1] * y + phase[1]),
                np.sin(freq[2] * z + phase[2]),
            ], axis=1).astype(np.float32)
            identity[k] = field * 0.25
        # normalize each identity direction to unit Frobenius norm
        for k in range(n_identity):
            nrm = float(np.linalg.norm(identity[k]))
            if nrm > 1e-8:
                identity[k] /= nrm

        # Expression directions → these become the GLB's MORPH TARGETS (per-expression vertex deltas).
        expression = np.zeros((n_expression, v, 3), dtype=np.float32)
        for k in range(n_expression):
            freq = rng.uniform(1.0, 3.0, size=3)
            phase = rng.uniform(0, 2 * np.pi, size=3)
            field = np.stack([
                np.cos(freq[0] * y + phase[0]),
                np.cos(freq[1] * z + phase[1]),
                np.cos(freq[2] * x + phase[2]),
            ], axis=1).astype(np.float32)
            nrm = float(np.linalg.norm(field))
            expression[k] = (field / nrm if nrm > 1e-8 else field) * 0.3

        return CharacterBasis(
            mean=mean.astype(np.float32),
            faces=faces.astype(np.uint32),
            identity_dirs=identity,
            expression_dirs=expression,
            source="synthetic",
        )


def load_basis(flame_npz: str | None = None) -> CharacterBasis:
    """Return the character basis. If `flame_npz` points at a real FLAME 2023 Open `.npz`
    (keys: v_template/mean, f/faces, shapedirs, expdirs), load it; otherwise return the synthetic
    stand-in. THIS is the single swap point — downstream code is identical for synthetic vs real."""
    if flame_npz:
        data = np.load(flame_npz)
        mean = np.asarray(data[("v_template" if "v_template" in data else "mean")], dtype=np.float32)
        faces = np.asarray(data[("f" if "f" in data else "faces")], dtype=np.uint32)
        shapedirs = np.asarray(data["shapedirs"], dtype=np.float32)   # (V,3,Ki)
        expdirs = np.asarray(data["expdirs"], dtype=np.float32)        # (V,3,Ke)
        identity = np.transpose(shapedirs, (2, 0, 1))                  # (Ki,V,3)
        expression = np.transpose(expdirs, (2, 0, 1))                 # (Ke,V,3)
        return CharacterBasis(mean, faces, identity, expression, source="flame-2023-open")
    return SyntheticFlameBasis.build()


def stylize_delta(basis: CharacterBasis, amount: float) -> np.ndarray:
    """The fixed proportion-exaggeration delta applied to the IDENTITY coefficient vector, scaled by
    `amount` ∈ [0,1] (0 = realistic, 1 = full arcane). Pure PCA-space transform (research memo §2):
    no remodeling, the output is always a valid face. Returns a (Ki,) coefficient delta."""
    amount = float(np.clip(amount, 0.0, 1.0))
    ki = basis.identity_dirs.shape[0]
    delta = np.zeros(ki, dtype=np.float32)
    for _name, (idx, weight) in STYLIZE_AXES.items():
        if 0 <= idx < ki:
            delta[idx] += weight
    return delta * amount


def resolve_vertices(
    basis: CharacterBasis,
    identity: np.ndarray,
    stylize_amount: float = 0.0,
) -> np.ndarray:
    """Resolve the identity coefficient vector (+ stylize delta) to a neutral mesh: the linear
    morphable-model evaluation `mean + Σ βᵢ·basisᵢ`. Returns (V,3) float32 vertices."""
    ki = basis.identity_dirs.shape[0]
    beta = np.zeros(ki, dtype=np.float32)
    n = min(ki, len(identity))
    beta[:n] = np.asarray(identity, dtype=np.float32)[:n]
    beta = beta + stylize_delta(basis, stylize_amount)
    verts = basis.mean.copy()
    # einsum: (Ki,) · (Ki,V,3) → (V,3)
    verts += np.einsum("k,kvc->vc", beta, basis.identity_dirs)
    return verts.astype(np.float32)


def resolve_morph_targets(basis: CharacterBasis, expression: np.ndarray) -> list[np.ndarray]:
    """Per-expression vertex DELTAS that become the GLB's morph targets. Each target j is the
    expression direction j scaled by ψ_j (so a renderer can blend them live AND the evolver can
    evolve the weights). Returns a list of (V,3) float32 delta arrays."""
    ke = basis.expression_dirs.shape[0]
    psi = np.zeros(ke, dtype=np.float32)
    n = min(ke, len(expression))
    psi[:n] = np.asarray(expression, dtype=np.float32)[:n]
    targets: list[np.ndarray] = []
    for j in range(ke):
        targets.append((basis.expression_dirs[j] * psi[j]).astype(np.float32))
    return targets


def _compute_normals(verts: np.ndarray, faces: np.ndarray) -> np.ndarray:
    """Smooth per-vertex normals (area-weighted face-normal accumulation). Renderer-neutral."""
    normals = np.zeros_like(verts, dtype=np.float32)
    v0 = verts[faces[:, 0]]
    v1 = verts[faces[:, 1]]
    v2 = verts[faces[:, 2]]
    fn = np.cross(v1 - v0, v2 - v0)
    for i in range(3):
        np.add.at(normals, faces[:, i], fn)
    lens = np.linalg.norm(normals, axis=1, keepdims=True)
    lens[lens < 1e-8] = 1.0
    return (normals / lens).astype(np.float32)


def _pad4(b: bytes, pad: bytes = b"\x00") -> bytes:
    """glTF requires 4-byte alignment of chunk + buffer-view boundaries. The JSON chunk must be
    padded with SPACE (0x20); the BIN chunk + buffer views with zeros (glTF 2.0 §4.4.3). The default
    is zero-padding; callers writing the JSON chunk pass pad=b" "."""
    rem = len(b) % 4
    return b + (pad * (4 - rem) if rem else b"")


def write_glb(
    out_path: str | Path,
    verts: np.ndarray,
    faces: np.ndarray,
    morph_targets: list[np.ndarray] | None = None,
    morph_weights: list[float] | None = None,
    name: str = "character",
) -> Path:
    """Write a self-contained glTF-2.0 binary (.glb) with POSITION, NORMAL, indices, and (optionally)
    POSITION morph TARGETS. No external glTF library — a tiny spec-conformant emitter, so the only
    dependency is numpy. The morph-target write is the engine gap the research memo §5 names; here it
    is closed at the source-of-truth (the resolver), and gltf_exporter.gd separately learns to
    round-trip blend shapes Godot already imports from this GLB."""
    verts = np.ascontiguousarray(verts, dtype=np.float32)
    faces = np.ascontiguousarray(faces, dtype=np.uint32)
    normals = _compute_normals(verts, faces)
    morph_targets = morph_targets or []

    bin_chunks: list[bytes] = []
    buffer_views: list[dict[str, Any]] = []
    accessors: list[dict[str, Any]] = []
    offset = 0

    def add_view(data: bytes, target: int | None = None) -> int:
        nonlocal offset
        padded = _pad4(data)
        bin_chunks.append(padded)
        bv: dict[str, Any] = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            bv["target"] = target
        buffer_views.append(bv)
        offset += len(padded)
        return len(buffer_views) - 1

    def vec3_accessor(view: int, arr: np.ndarray) -> int:
        accessors.append({
            "bufferView": view, "componentType": _FLOAT, "count": int(arr.shape[0]),
            "type": "VEC3",
            "min": [float(arr[:, 0].min()), float(arr[:, 1].min()), float(arr[:, 2].min())],
            "max": [float(arr[:, 0].max()), float(arr[:, 1].max()), float(arr[:, 2].max())],
        })
        return len(accessors) - 1

    pos_view = add_view(verts.tobytes(), _ARRAY_BUFFER)
    pos_acc = vec3_accessor(pos_view, verts)
    nrm_view = add_view(normals.tobytes(), _ARRAY_BUFFER)
    nrm_acc = vec3_accessor(nrm_view, normals)

    idx_flat = faces.reshape(-1).astype(np.uint32)
    idx_view = add_view(idx_flat.tobytes(), _ELEMENT_ARRAY_BUFFER)
    accessors.append({
        "bufferView": idx_view, "componentType": _UINT,
        "count": int(idx_flat.shape[0]), "type": "SCALAR",
    })
    idx_acc = len(accessors) - 1

    targets_json: list[dict[str, int]] = []
    for tgt in morph_targets:
        tgt = np.ascontiguousarray(tgt, dtype=np.float32)
        tv = add_view(tgt.tobytes(), _ARRAY_BUFFER)
        ta = vec3_accessor(tv, tgt)
        targets_json.append({"POSITION": ta})

    primitive: dict[str, Any] = {
        "attributes": {"POSITION": pos_acc, "NORMAL": nrm_acc},
        "indices": idx_acc,
        "mode": _TRIANGLES,
    }
    if targets_json:
        primitive["targets"] = targets_json

    mesh: dict[str, Any] = {"name": name, "primitives": [primitive]}
    if targets_json:
        w = morph_weights if morph_weights is not None else [0.0] * len(targets_json)
        mesh["weights"] = [float(x) for x in (list(w) + [0.0] * len(targets_json))[: len(targets_json)]]

    bin_blob = b"".join(bin_chunks)
    gltf = {
        "asset": {"version": "2.0", "generator": "resonance-character-resolver"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": name}],
        "meshes": [mesh],
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(bin_blob)}],
    }

    json_bytes = _pad4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), pad=b" ")
    bin_bytes = _pad4(bin_blob)
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, total)            # magic "glTF", version 2, length
    out += struct.pack("<II", len(json_bytes), 0x4E4F534A)       # JSON chunk header ("JSON")
    out += json_bytes
    out += struct.pack("<II", len(bin_bytes), 0x004E4942)        # BIN chunk header ("BIN\0")
    out += bin_bytes

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(bytes(out))
    return out_path


def make_scene_node(
    genome: dict[str, Any],
    glb_path: str,
    morph_weights: dict[str, float] | None = None,
    name: str = "character",
) -> dict[str, Any]:
    """The renderer-neutral `scene_node` descriptor that rides the existing `mesh.source` seam.
    `source="character"` is an ADDITIVE sibling of "glb"/"primitive" — the genome travels as data
    (provenance + evolvable), the GLB is the resolved geometry the delegate loads (reusing the glb
    path). Matches GodotSceneRenderer.is_scene_node (translation/rotation/scale present)."""
    return {
        "name": name,
        "translation": [0.0, 0.0, 0.0],
        "rotation": [0.0, 0.0, 0.0, 1.0],
        "scale": [1.0, 1.0, 1.0],
        "mesh": {
            "source": "character",
            "genome": genome,
            "glb": glb_path,
            "morph_weights": morph_weights or {},
        },
        "children": [],
    }


def resolve(
    identity: list[float],
    expression: list[float] | None = None,
    stylize_amount: float = 0.0,
    out_glb: str | Path = "character.glb",
    basis: CharacterBasis | None = None,
    name: str = "character",
) -> dict[str, Any]:
    """Top-level: genome vector → GLB (with morph targets) → scene_node descriptor. Returns the
    scene_node dict; writes the GLB to `out_glb`. Deterministic given the (synthetic) basis."""
    basis = basis or load_basis()
    expression = expression or []
    verts = resolve_vertices(basis, np.asarray(identity, dtype=np.float32), stylize_amount)
    targets = resolve_morph_targets(basis, np.asarray(expression, dtype=np.float32))
    weights = [float(x) for x in expression][: len(targets)]
    glb_path = write_glb(out_glb, verts, basis.faces, targets, weights, name=name)
    genome = {
        "kind": "character",
        "identity": [float(x) for x in identity],
        "expression": [float(x) for x in (expression or [])],
        "stylize_amount": float(stylize_amount),
        "basis_source": basis.source,
        "n_vertices": basis.n_vertices,
    }
    morph_weights = {f"expr{j}": float(weights[j]) for j in range(len(weights))}
    return make_scene_node(genome, str(glb_path), morph_weights, name=name)


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="FLAME-style character genome → GLB (with morph targets) → scene_node.")
    ap.add_argument("--identity", type=float, nargs="*", default=[1.0, -0.5, 0.7],
                    help="identity PCA coefficients (β vector)")
    ap.add_argument("--expression", type=float, nargs="*", default=[0.3, 0.0],
                    help="expression PCA coefficients (ψ vector) → morph-target weights")
    ap.add_argument("--stylize-amount", type=float, default=0.0,
                    help="0=realistic, 1=arcane proportion-exaggeration")
    ap.add_argument("--flame-npz", default=None,
                    help="path to a real FLAME 2023 Open .npz; omit to use the synthetic basis")
    ap.add_argument("--out", default="character.glb", help="output GLB path")
    ap.add_argument("--emit-scene-node", default=None, help="also write the scene_node JSON here")
    ap.add_argument("--name", default="character")
    args = ap.parse_args(argv)

    basis = load_basis(args.flame_npz)
    node = resolve(args.identity, args.expression, args.stylize_amount, args.out, basis, args.name)
    print(json.dumps(node, separators=(",", ":")))
    if args.emit_scene_node:
        Path(args.emit_scene_node).write_text(json.dumps(node, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
