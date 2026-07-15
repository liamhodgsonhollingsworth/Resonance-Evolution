#!/usr/bin/env python3
"""stool_tunable.py -- a parameterized, live-tunable rebuild of the steampunk
pipe stool, REUSING the real proc3d shared primitives (``parametric_part`` /
``parts`` / ``assembly`` / ``linalg`` / ``gear_gen``) from Wavelet's
``Alethea-cc/tools/proc3d/`` via cross-repo import.

This mirrors ``Alethea-cc/tools/proc3d/targets/stool.py``'s ``build_stool()``
assembly logic exactly (same corner/leg/foot/stretcher/flange/tee structure),
but takes an explicit ``params`` dict instead of module-level constants, so
every real dimension of the stool is a live-tunable float -- the
Resonance-Evolution side of dropped-work-recovery item 3 (interactive 3D
mockup page + live param tuning, Liam msg 1526751917060128809).

Deliberately does NOT edit ``targets/stool.py`` (a different repo's artifact
definition) -- per the "new nodes + connections, never edit a primitive"
convention, this is a NEW, separate generator in THIS repo that composes the
same shared, reuse-intended part primitives with the dimensions exposed as
parameters. At ``DEFAULTS`` values this produces the same stool shape
``targets/stool.py`` does (compared field-by-field against its module
constants S / LEG_R / LEG_WALL / LEG_BOT / LEG_TOP / STRETCH_Z / SEAT_R /
SEAT_THICK as of 2026-07-15).

schema-version: 1.0.0
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def _find_wavelet_proc3d_dir() -> Path:
    """Locate Wavelet's ``Alethea-cc/tools/proc3d`` directory (the shared
    proc3d primitive library this module reuses) without assuming a fixed
    drive letter.

    Resolution order:
      1. ``WAVELET_ROOT`` env var, if set.
      2. Walk up from this file looking for a ``repos`` dir whose parent
         also has an ``Alethea-cc`` sibling (the standard
         ``<wavelet_root>/repos/Resonance-Evolution/...`` worktree layout
         this file was built under, per CLAUDE.md's "Repos
         G:\\Wavelet\\repos\\<name>\\" convention -- works from ANY worktree
         location nested under ``repos/Resonance-Evolution``).
      3. ``G:\\Wavelet`` (this host's documented canonical path, CLAUDE.md
         "Current state and paths").
    """
    candidates = []
    env = os.environ.get("WAVELET_ROOT")
    if env:
        candidates.append(Path(env))

    here = Path(__file__).resolve()
    for ancestor in here.parents:
        if ancestor.name == "repos":
            candidates.append(ancestor.parent)
            break

    candidates.append(Path("G:/Wavelet"))

    for root in candidates:
        proc3d = root / "Alethea-cc" / "tools" / "proc3d"
        if (proc3d / "parametric_part.py").is_file():
            return proc3d
    raise RuntimeError(
        "could not locate Wavelet's Alethea-cc/tools/proc3d (checked "
        f"{[str(c) for c in candidates]}) -- set WAVELET_ROOT to the Wavelet "
        "checkout root if it is not at the conventional repos/<name> nesting "
        "or G:/Wavelet"
    )


_PROC3D_DIR = _find_wavelet_proc3d_dir()
if str(_PROC3D_DIR) not in sys.path:
    sys.path.insert(0, str(_PROC3D_DIR))

import parametric_part as PP  # noqa: E402
import parts as _parts  # noqa: E402,F401  (side-effect: registers pipe/connector/etc. families)
from parts import prim  # noqa: E402
from assembly import Assembly  # noqa: E402
from linalg import Transform, rot_align, rot_axis_angle, mat_mul  # noqa: E402
from parametric_part import PartInstance, Port  # noqa: E402


# ── the real tunable dimensions (mm), matching targets/stool.py's module
#    constants at their default values ─────────────────────────────────────
DEFAULTS: Dict[str, float] = {
    "leg_spread": 92.0,       # targets/stool.py: S -- leg square half-offset
    "leg_radius": 12.0,       # LEG_R -- leg pipe outer radius
    "leg_wall": 3.0,          # LEG_WALL -- pipe wall thickness
    "leg_bottom_z": 92.0,     # LEG_BOT -- z of straight-leg bottom
    "leg_top_z": 415.0,       # LEG_TOP -- z of straight-leg top (~overall height)
    "stretcher_z": 200.0,     # STRETCH_Z -- stretcher-ring height
    "seat_radius": 150.0,     # SEAT_R
    "seat_thickness": 42.0,   # SEAT_THICK
}

# (min, max) sane ranges for the live-tuning UI -- "tunable-everything ideal":
# every real dimension above gets a slider with a sensible physical range.
RANGES: Dict[str, tuple] = {
    "leg_spread": (50.0, 170.0),
    "leg_radius": (6.0, 26.0),
    "leg_wall": (1.0, 8.0),
    "leg_bottom_z": (30.0, 160.0),
    "leg_top_z": (260.0, 620.0),
    "stretcher_z": (60.0, 560.0),
    "seat_radius": (80.0, 260.0),
    "seat_thickness": (15.0, 85.0),
}


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _sanitize(params: Dict[str, Any]) -> Dict[str, float]:
    """Merge ``params`` over ``DEFAULTS``, clamp to ``RANGES``, and enforce
    the geometric invariants build_stool() below assumes (leg_top strictly
    above leg_bottom; stretcher strictly between them) -- tunable-everything
    still needs to stay assembleable for arbitrary slider combinations."""
    merged = dict(DEFAULTS)
    for k, v in (params or {}).items():
        if k in DEFAULTS:
            try:
                merged[k] = float(v)
            except (TypeError, ValueError):
                pass
    for k, (lo, hi) in RANGES.items():
        merged[k] = _clamp(merged[k], lo, hi)

    min_gap = 40.0
    if merged["leg_top_z"] < merged["leg_bottom_z"] + min_gap:
        merged["leg_top_z"] = merged["leg_bottom_z"] + min_gap
    lo = merged["leg_bottom_z"] + 20.0
    hi = merged["leg_top_z"] - 20.0
    if hi < lo:
        hi = lo
    merged["stretcher_z"] = _clamp(merged["stretcher_z"], lo, hi)
    return merged


def _T(pos, z_axis=(0.0, 0.0, 1.0), spin=0.0) -> Transform:
    R = rot_align((0.0, 0.0, 1.0), z_axis)
    if abs(spin) > 1e-12:
        R = mat_mul(rot_axis_angle(z_axis, spin), R)
    return Transform(R, tuple(map(float, pos)))


def _wood_seat(radius: float, thick: float) -> PartInstance:
    v, t = prim.solid_cylinder(radius, thick, seg=52, z0=0.0)
    ports = [
        Port("bottom", "mount", position=(0, 0, 0), axis=(0, 0, -1), meta={"radius": radius}),
        Port("top", "mount", position=(0, 0, thick), axis=(0, 0, 1), meta={"radius": radius}),
    ]
    import gear_gen  # local import: sibling of parametric_part.py, already on sys.path

    return PartInstance(
        "wood_seat", {"radius": radius, "thick": thick}, v, t, ports,
        {"material": "reclaimed_wood"}, gear_gen.manifold_check(v, t),
    )


def build_stool(params: Optional[Dict[str, Any]] = None) -> Assembly:
    """Build the Assembly for the given (sanitized) params dict. Structurally
    identical to ``targets/stool.py``'s ``build_stool()`` -- corners, legs,
    bent feet, tee-junction stretcher ring, flanged seat mount -- with every
    dimension read from ``params`` instead of a module constant."""
    p = _sanitize(params or {})
    S = p["leg_spread"]
    LEG_R = p["leg_radius"]
    LEG_WALL = p["leg_wall"]
    LEG_BOT = p["leg_bottom_z"]
    LEG_TOP = p["leg_top_z"]
    STRETCH_Z = p["stretcher_z"]
    SEAT_R = p["seat_radius"]
    SEAT_THICK = p["seat_thickness"]

    CORNERS = [(S, S), (S, -S), (-S, -S), (-S, S)]

    pipe = PP.get("pipe")
    conn = PP.get("pipe_connector")
    asm = Assembly("steampunk_stool")

    asm.add("seat", _wood_seat(SEAT_R, SEAT_THICK), Transform.translation((0.0, 0.0, LEG_TOP + LEG_R * 0.5)))

    leg = pipe.build({"length": LEG_TOP - LEG_BOT, "outer_radius": LEG_R, "wall": LEG_WALL})
    flange = conn.build({"kind": "flange", "radius": LEG_R, "bolt_holes": 4})
    for i, (x, y) in enumerate(CORNERS):
        th = math.atan2(y, x)
        cx, cy = math.cos(th), math.sin(th)
        asm.add(f"leg{i}", leg, Transform.translation((x, y, LEG_BOT)))
        asm.mate(f"leg{i}", "end_b", flange, f"flange{i}", "socket", flip=True)
        foot = pipe.build(
            {
                "outer_radius": LEG_R,
                "wall": LEG_WALL,
                "path": [
                    [x, y, LEG_BOT + 4],
                    [x + cx * 42, y + cy * 42, 55],
                    [x + cx * 70, y + cy * 70, 6],
                ],
            }
        )
        asm.add(f"foot{i}", foot, Transform.identity())
        tee = conn.build({"kind": "tee", "radius": LEG_R})
        asm.add(f"tee{i}", tee, _T((x, y, STRETCH_Z), z_axis=(0, 0, 1), spin=th))

    for i in range(4):
        (x0, y0), (x1, y1) = CORNERS[i], CORNERS[(i + 1) % 4]
        d = (x1 - x0, y1 - y0, 0.0)
        length = math.hypot(d[0], d[1])
        seg_pipe = pipe.build({"length": length, "outer_radius": LEG_R * 0.85, "wall": LEG_WALL})
        asm.add(f"stretch{i}", seg_pipe, _T((x0, y0, STRETCH_Z), z_axis=d))

    return asm


def default_params() -> Dict[str, float]:
    return dict(DEFAULTS)


def sanitize_params(params: Optional[Dict[str, Any]]) -> Dict[str, float]:
    return _sanitize(params or {})


__all__ = ["DEFAULTS", "RANGES", "build_stool", "default_params", "sanitize_params"]


if __name__ == "__main__":
    a = build_stool()
    v, t = a.combined_mesh()
    print(f"stool_tunable (defaults): {len(a.parts)} parts, {len(v)} verts, {len(t)} tris")
