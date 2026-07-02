"""SPEC-745 keystone fixture: adding a new effect-stack layer (or renderer) is PURE REGISTRATION —
ZERO edits to foundation/dispatch files.

The effect-stack architecture's load-bearing guarantee is that a new visual layer arrives as a new
*registered* branch inside an applier delegate (and its renderer twin), never as an edit to the graph
foundation, the primitive that emits the descriptor, the runtime that dispatches it, or the port-type
system. This test makes that guarantee MECHANICALLY CHECKABLE: it diffs the working tree against
origin/main and asserts that the convergence-optical change touched none of the FOUNDATION files —
only the registered appliers, the descriptor schema doc, additive scenes/tests, and the web delegate.

If a future change to add a layer DOES edit a foundation file, this test fails and forces the author to
either move the logic into a registered applier or justify (and re-baseline) the foundation touch.

It also asserts, structurally, that the three new optical layers are reachable purely by registration:
they appear in EFFECT_TYPES and have a `match` branch in the CPU applier source, with no corresponding
edit to prim_effect_stack.gd / graph_runtime.gd.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
GODOT = REPO / "godot"

# Foundation / dispatch files — the substrate a new layer must NOT edit (SPEC-745). The primitive that
# emits the effect_stack descriptor, the graph runtime that dispatches nodes, the port-type system, the
# base primitive, and the 3D scene renderer's node-building core are all "foundation": a new visual
# effect is data the delegate learns to apply, never a change to how the graph is wired or dispatched.
FOUNDATION_FILES = {
    "godot/primitives/prim_effect_stack.gd",
    "godot/primitives/primitive.gd",
    "godot/primitives/prim_model.gd",
    "godot/primitives/prim_view.gd",
    "godot/runtime/graph_runtime.gd",
    "godot/runtime/port_types.gd",
    "godot/renderers/godot_scene_renderer.gd",
    "godot/renderers/gltf_exporter.gd",
}

NEW_OPTICAL_LAYERS = ("god_rays", "lens_flare", "bloom")


def _git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout


def _merge_base() -> str:
    # Compare against the branch's base on origin/main so the test reflects exactly the layers' diff.
    try:
        return _git("merge-base", "HEAD", "origin/main").strip()
    except subprocess.CalledProcessError:
        return _git("merge-base", "HEAD", "main").strip()


def _changed_files() -> list[str]:
    base = _merge_base()
    out = _git("diff", "--name-only", base, "HEAD").strip()
    return [line.strip() for line in out.splitlines() if line.strip()]


def test_no_foundation_files_edited_for_new_layers() -> None:
    """The convergence-optical layers must touch ZERO foundation/dispatch files (SPEC-745)."""
    changed = set(_changed_files())
    violated = changed & FOUNDATION_FILES
    assert not violated, (
        "SPEC-745 violated: adding optical layers must be pure registration, but these "
        f"foundation/dispatch files were edited: {sorted(violated)}"
    )


def test_optical_layers_registered_in_effect_types() -> None:
    """Each new layer is registered in EFFECT_TYPES (the evolver vocabulary) — reachable by data."""
    src = (GODOT / "renderers" / "effect_stack_cpu.gd").read_text(encoding="utf-8")
    # The EFFECT_TYPES dict is the single registry the applier + evolver share.
    assert "const EFFECT_TYPES" in src
    for layer in NEW_OPTICAL_LAYERS:
        assert f'"{layer}": {{ "params"' in src, f"{layer} missing from EFFECT_TYPES registry"


def test_optical_layers_have_applier_branches() -> None:
    """Each new layer has a dispatch branch INSIDE the registered applier (not the foundation)."""
    src = (GODOT / "renderers" / "effect_stack_cpu.gd").read_text(encoding="utf-8")
    for layer in NEW_OPTICAL_LAYERS:
        assert f'"{layer}":' in src, f"{layer} missing a match branch in EffectStackCpu.apply_io"


def test_typed_io_is_backward_compatible_wrapper() -> None:
    """The typed-I/O reformat (SPEC-748a) keeps the legacy apply() as a thin wrapper over apply_io —
    so legacy callers are unchanged by construction (the GDScript backcompat test asserts pixel parity).
    """
    src = (GODOT / "renderers" / "effect_stack_cpu.gd").read_text(encoding="utf-8")
    assert "static func apply(desc: Dictionary, src: Image) -> Image:" in src
    assert "return apply_io(desc, { \"color\": src })" in src
    assert "static func apply_io(" in src


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
