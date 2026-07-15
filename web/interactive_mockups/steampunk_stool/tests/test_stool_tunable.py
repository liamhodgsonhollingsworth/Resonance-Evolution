#!/usr/bin/env python3
"""test_stool_tunable.py -- smoke tests for tools/stool_tunable.py (the
parameterized, cross-repo-reusing steampunk-stool generator behind the
interactive 3D mockup page, dropped-work-recovery item 3).

Standalone runner (no pytest dependency), matching the convention every other
proc3d test file in Wavelet already uses (Alethea-cc/tools/proc3d/test_*.py).
Run:
    py tests/test_stool_tunable.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOLS_DIR = HERE.parent / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

PASSES: list[str] = []
FAILS: list[str] = []


def _check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSES.append(name)
        print(f"PASS  {name}")
    else:
        FAILS.append(f"{name}: {detail}")
        print(f"FAIL  {name}: {detail}")


def test_defaults_match_targets_stool_module_constants() -> None:
    import stool_tunable as st

    # Alethea-cc/tools/proc3d/targets/stool.py's own module constants, as of
    # 2026-07-15 (S, LEG_R, LEG_WALL, LEG_BOT, LEG_TOP, STRETCH_Z, SEAT_R,
    # SEAT_THICK) -- this generator's DEFAULTS must reproduce that stool.
    expected = {
        "leg_spread": 92.0, "leg_radius": 12.0, "leg_wall": 3.0,
        "leg_bottom_z": 92.0, "leg_top_z": 415.0, "stretcher_z": 200.0,
        "seat_radius": 150.0, "seat_thickness": 42.0,
    }
    _check("defaults_match_stool_py", st.DEFAULTS == expected, str(st.DEFAULTS))


def test_build_stool_default_has_21_parts() -> None:
    import stool_tunable as st

    asm = st.build_stool()
    _check("stool_has_21_parts", len(asm.parts) == 21, str(len(asm.parts)))
    verts, tris = asm.combined_mesh()
    _check("stool_has_verts_and_tris", len(verts) > 0 and len(tris) > 0)


def test_build_stool_reflects_param_overrides() -> None:
    import stool_tunable as st

    asm_default = st.build_stool()
    asm_bigger = st.build_stool({"seat_radius": 220.0})
    v_default, _ = asm_default.combined_mesh()
    v_bigger, _ = asm_bigger.combined_mesh()
    # a bigger seat radius must move at least the seat's own vertices outward
    max_r_default = max((x * x + y * y) ** 0.5 for (x, y, z) in v_default)
    max_r_bigger = max((x * x + y * y) ** 0.5 for (x, y, z) in v_bigger)
    _check("bigger_seat_radius_grows_mesh_extent", max_r_bigger > max_r_default,
           f"{max_r_bigger} vs {max_r_default}")


def test_sanitize_params_clamps_to_ranges() -> None:
    import stool_tunable as st

    p = st.sanitize_params({"seat_radius": 99999.0, "leg_wall": -5.0})
    lo, hi = st.RANGES["seat_radius"]
    _check("seat_radius_clamped_to_max", p["seat_radius"] == hi, str(p["seat_radius"]))
    lo2, hi2 = st.RANGES["leg_wall"]
    _check("leg_wall_clamped_to_min", p["leg_wall"] == lo2, str(p["leg_wall"]))


def test_sanitize_params_enforces_leg_top_above_leg_bottom() -> None:
    import stool_tunable as st

    p = st.sanitize_params({"leg_bottom_z": 150.0, "leg_top_z": 155.0})
    _check("leg_top_stays_above_leg_bottom", p["leg_top_z"] >= p["leg_bottom_z"] + 40.0, str(p))


def test_unknown_param_keys_are_ignored_not_raised() -> None:
    import stool_tunable as st

    p = st.sanitize_params({"not_a_real_param": 5.0})
    _check("unknown_key_ignored_no_raise", "not_a_real_param" not in p)


def test_canonical_glb_exporter_roundtrips_the_assembly() -> None:
    """Confirms this module composes cleanly with the CANONICAL proc3d GLB
    exporter (Alethea-cc/tools/proc3d/glb_export.py, PR #934) -- this page
    does not carry its own GLB writer."""
    import stool_tunable as st

    proc3d_dir = st._PROC3D_DIR  # noqa: SLF001 (test-only introspection)
    if str(proc3d_dir) not in sys.path:
        sys.path.insert(0, str(proc3d_dir))
    import glb_export as canonical

    asm = st.build_stool()
    data = canonical.assembly_to_glb(asm)
    ok, reason = canonical.validate_glb_bytes(data)
    _check("canonical_exporter_produces_valid_glb", ok, reason)


def _run_all() -> None:
    test_defaults_match_targets_stool_module_constants()
    test_build_stool_default_has_21_parts()
    test_build_stool_reflects_param_overrides()
    test_sanitize_params_clamps_to_ranges()
    test_sanitize_params_enforces_leg_top_above_leg_bottom()
    test_unknown_param_keys_are_ignored_not_raised()
    test_canonical_glb_exporter_roundtrips_the_assembly()


def test_all_invariants_pytest_visible() -> None:
    PASSES.clear()
    FAILS.clear()
    _run_all()
    assert not FAILS, "stool_tunable tests failed:\n  - " + "\n  - ".join(FAILS)


def main() -> int:
    PASSES.clear()
    FAILS.clear()
    _run_all()
    print(f"\nPassed: {len(PASSES)}")
    print(f"Failed: {len(FAILS)}")
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
