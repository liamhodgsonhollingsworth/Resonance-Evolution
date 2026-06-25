"""Tests for tools/character_resolver.py — the FLAME-style character genome resolver.

Covers Character Increment A's Python half (the Godot half is headless_character_test.gd):
  - resolve() emits a valid scene_node with mesh.source="character" + the genome as data;
  - the written GLB is structurally valid (glTF magic, JSON+BIN chunks, 4-byte aligned) and
    carries POSITION morph TARGETS (the engine gap the research memo §5 names, closed at source);
  - two distinct identity genomes resolve to two geometrically DISTINCT meshes;
  - the stylize_amount boil-down (0=realistic, 1=arcane) is a continuous coefficient transform that
    perturbs geometry without breaking the mesh (same vertex/face count, still valid);
  - the synthetic basis is deterministic (reproducible), and the real-FLAME swap point exists with
    matching array shapes (so dropping in real weights needs no code change).
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np
import pytest

import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import character_resolver as cr  # noqa: E402


pytestmark = pytest.mark.no_file_source_tmp


# ---------------------------------------------------------------------------------------------------
# GLB structure helpers
# ---------------------------------------------------------------------------------------------------

def _read_glb(path: Path) -> tuple[dict, bytes]:
    """Parse a .glb into (json_chunk_dict, bin_chunk_bytes), asserting the container framing."""
    raw = path.read_bytes()
    magic, version, length = struct.unpack("<III", raw[:12])
    assert magic == 0x46546C67, "glTF magic"
    assert version == 2
    assert length == len(raw), "header length matches file"
    jlen, jtype = struct.unpack("<II", raw[12:20])
    assert jtype == 0x4E4F534A, "JSON chunk type"
    jbytes = raw[20 : 20 + jlen]
    gltf = json.loads(jbytes.decode("utf-8"))
    blen, btype = struct.unpack("<II", raw[20 + jlen : 28 + jlen])
    assert btype == 0x004E4942, "BIN chunk type"
    bin_bytes = raw[28 + jlen : 28 + jlen + blen]
    # 4-byte alignment of both chunks (the spec requirement that the realistic/arcane padding bug hit)
    assert jlen % 4 == 0, "JSON chunk 4-byte aligned"
    assert blen % 4 == 0, "BIN chunk 4-byte aligned"
    return gltf, bin_bytes


def _verts(gltf: dict, bin_bytes: bytes) -> np.ndarray:
    """Read the POSITION accessor back out of a parsed GLB as an (N,3) float array."""
    prim = gltf["meshes"][0]["primitives"][0]
    acc = gltf["accessors"][prim["attributes"]["POSITION"]]
    bv = gltf["bufferViews"][acc["bufferView"]]
    off = bv.get("byteOffset", 0)
    n = acc["count"]
    data = bin_bytes[off : off + n * 3 * 4]
    return np.frombuffer(data, dtype=np.float32).reshape(n, 3)


# ---------------------------------------------------------------------------------------------------
# scene_node descriptor
# ---------------------------------------------------------------------------------------------------

def test_resolve_emits_character_scene_node(tmp_path):
    out = tmp_path / "face.glb"
    node = cr.resolve([1.0, -0.5, 0.7], expression=[0.3, 0.0], stylize_amount=0.0, out_glb=out)
    # is_scene_node shape (translation/rotation/scale present), and the additive mesh.source.
    for k in ("translation", "rotation", "scale", "mesh", "children"):
        assert k in node
    mesh = node["mesh"]
    assert mesh["source"] == "character"
    assert mesh["genome"]["kind"] == "character"
    assert mesh["genome"]["identity"] == [1.0, -0.5, 0.7]
    assert mesh["genome"]["basis_source"] == "synthetic"
    assert out.exists()
    # JSON round-trippable (pure data, no objects).
    assert json.loads(json.dumps(node)) == node


def test_glb_is_valid_and_has_morph_targets(tmp_path):
    out = tmp_path / "face.glb"
    cr.resolve([0.5, 0.5], expression=[0.2, -0.1, 0.4], stylize_amount=0.0, out_glb=out)
    gltf, _ = _read_glb(out)
    prim = gltf["meshes"][0]["primitives"][0]
    assert "POSITION" in prim["attributes"]
    assert "NORMAL" in prim["attributes"]
    assert "indices" in prim
    # morph targets: one per expression DIRECTION in the basis (the resolver zero-pads a shorter input
    # coefficient vector), each a POSITION delta accessor. Synthetic basis has 4 expression directions.
    n_targets = cr.load_basis().expression_dirs.shape[0]
    assert "targets" in prim and len(prim["targets"]) == n_targets
    for t in prim["targets"]:
        assert "POSITION" in t
    # mesh-level default weights present (so a renderer/evolver can blend them).
    assert "weights" in gltf["meshes"][0]
    assert len(gltf["meshes"][0]["weights"]) == n_targets


def test_morph_target_padding_is_spec_aligned(tmp_path):
    # Regression: stylize_amount=1.0 vs 0.0 shifts the JSON length; the JSON chunk must be SPACE-padded
    # to 4 bytes or an independent validator rejects it. _read_glb asserts the alignment for both.
    for amt in (0.0, 1.0):
        out = tmp_path / f"face_{amt}.glb"
        cr.resolve([1.0, -0.5, 0.7], expression=[0.3, 0.0], stylize_amount=amt, out_glb=out)
        _read_glb(out)  # raises on misalignment / bad framing


# ---------------------------------------------------------------------------------------------------
# distinctness + stylize boil-down
# ---------------------------------------------------------------------------------------------------

def test_two_genomes_resolve_to_distinct_faces(tmp_path):
    a = tmp_path / "a.glb"
    b = tmp_path / "b.glb"
    cr.resolve([1.5, 0.0, -0.8, 0.3], expression=[0.2, 0.0], out_glb=a)
    cr.resolve([-0.6, 1.2, 0.4, -0.9], expression=[-0.1, 0.5], out_glb=b)
    va = _verts(*_read_glb(a))
    vb = _verts(*_read_glb(b))
    assert va.shape == vb.shape
    mean_abs_diff = float(np.mean(np.abs(va - vb)))
    assert mean_abs_diff > 1e-4, "two genomes must produce visibly different geometry"


def test_stylize_amount_is_a_valid_boil_down(tmp_path):
    """0 = realistic, 1 = arcane; both valid GLBs (same vert/face count), geometry differs, no break."""
    real = tmp_path / "real.glb"
    arc = tmp_path / "arc.glb"
    cr.resolve([1.0, -0.5, 0.7], expression=[0.2], stylize_amount=0.0, out_glb=real)
    cr.resolve([1.0, -0.5, 0.7], expression=[0.2], stylize_amount=1.0, out_glb=arc)
    g_real, b_real = _read_glb(real)
    g_arc, b_arc = _read_glb(arc)
    vr = _verts(g_real, b_real)
    var = _verts(g_arc, b_arc)
    assert vr.shape == var.shape, "no remodeling — same topology"
    assert float(np.mean(np.abs(vr - var))) > 1e-4, "arcane stylize visibly exaggerates proportions"
    assert np.isfinite(var).all(), "arcane mesh stays finite (valid)"


def test_stylize_amount_is_continuous(tmp_path):
    """The slider is continuous: an intermediate amount lands between realistic and arcane."""
    basis = cr.load_basis()
    v0 = cr.resolve_vertices(basis, np.array([1.0, -0.5, 0.7], dtype=np.float32), 0.0)
    v5 = cr.resolve_vertices(basis, np.array([1.0, -0.5, 0.7], dtype=np.float32), 0.5)
    v1 = cr.resolve_vertices(basis, np.array([1.0, -0.5, 0.7], dtype=np.float32), 1.0)
    d05 = float(np.mean(np.abs(v0 - v5)))
    d01 = float(np.mean(np.abs(v0 - v1)))
    assert 0.0 < d05 < d01, "halfway stylize is between realistic and full-arcane"


# ---------------------------------------------------------------------------------------------------
# determinism + real-FLAME swap point
# ---------------------------------------------------------------------------------------------------

def test_synthetic_basis_is_deterministic():
    a = cr.SyntheticFlameBasis.build()
    b = cr.SyntheticFlameBasis.build()
    assert np.array_equal(a.mean, b.mean)
    assert np.array_equal(a.identity_dirs, b.identity_dirs)
    assert np.array_equal(a.expression_dirs, b.expression_dirs)


def test_basis_shapes_match_flame_swap_contract():
    """The synthetic basis exposes exactly the arrays a real FLAME .npz loads into — so the swap in
    load_basis() needs no downstream change. (mean (V,3); identity (Ki,V,3); expression (Ke,V,3).)"""
    basis = cr.load_basis()
    v = basis.mean.shape[0]
    assert basis.mean.shape == (v, 3)
    assert basis.identity_dirs.ndim == 3 and basis.identity_dirs.shape[1:] == (v, 3)
    assert basis.expression_dirs.ndim == 3 and basis.expression_dirs.shape[1:] == (v, 3)
    assert basis.faces.shape[1] == 3
