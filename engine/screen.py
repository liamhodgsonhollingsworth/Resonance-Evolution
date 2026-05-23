"""
engine/screen.py — shared text-rendering + screen-rectangle paste helpers.

Lifted from three duplicate implementations in
``node_types/list_renderer.py``, ``node_types/chat_interface.py``, and
``node_types/computer.py`` so future text-displaying primitives compose
against ONE source of truth. The pre-extraction copies are now thin
import-shims pointing here; bit-identical output is the explicit
regression invariant (see ``tests/test_engine_screen.py``).

Made load-bearing by brief 03 commit 1 of the Resonance website
implementation arc (per
``notes/website_planning_arc/per_module_plans/03_node_primitive_elements.md``).
Brief 03's text-box primitive (N-F020) needs the same helpers; the
feasibility subagent flagged the extraction as recommended-but-not-
required. Brief 03 makes it required so its primitives don't add a
fourth copy.

Three families of helpers, each preserved verbatim from the pre-extraction
source (the list-renderer copy is the canonical form; the chat-interface
+ computer copies are byte-identical for the helpers they share):

- ``_get_font`` — PIL font loader with cross-platform fallback chain.
- ``_measure`` / ``_wrap`` / ``_wrap_line`` / ``_truncate`` —
  text-measurement + word-wrap primitives.
- ``_paste_onto_screen_rectangle`` — ray-cast + UV-sample primitive for
  pasting a 2D image array onto a 3D screen rectangle in the outer
  view.

The "underscore-prefixed" naming is preserved from the source so
in-place imports require zero call-site changes; the names ARE the API
that callers expect.

See also: ``notes/website_planning_arc/planning_briefs/existing_primitives_audit.md``
(toolbox-10 line — flagged the duplication this module resolves).
"""

from typing import Any, Dict, Optional

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# ``View`` + ``Channels`` are typed in engine.node; we import for type-hinting
# only so screen.py doesn't pick up a runtime dependency on the rest of the
# engine package. The functions accept any object with the duck-typed
# attributes used below — making screen.py importable in isolation (e.g.,
# from a test harness that doesn't boot the full engine).
from engine.node import Channels, View


# ---------------------------------------------------------------------------
# Font loading
# ---------------------------------------------------------------------------


def _get_font(size: int):
    """Try a few common system fonts; fall back to PIL's default.

    Verbatim from ``node_types/list_renderer.py:_get_font`` (and the
    identical copy at ``node_types/chat_interface.py:_get_font``). The
    font name list is the cross-platform fallback chain: Arial on
    Windows, DejaVu on Linux, FreeMono / Courier as last-resort
    monospace.
    """
    for name in ("arial.ttf", "Arial.ttf", "DejaVuSans.ttf", "FreeMono.ttf", "Courier.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except (IOError, OSError):
            continue
    return ImageFont.load_default()


# ---------------------------------------------------------------------------
# Text measurement + wrapping
# ---------------------------------------------------------------------------


def _measure(text, font) -> int:
    """Width of ``text`` in pixels under ``font``.

    Verbatim from ``node_types/list_renderer.py:_measure``. The PIL API
    moved from ``font.getsize`` to ``font.getlength`` between PIL 9 and
    10; the hasattr-based dispatch covers both. The crude
    ``len(text) * 7`` fallback exists for the
    ``ImageFont.load_default()`` case where neither method works under
    older Pillow.
    """
    if hasattr(font, "getlength"):
        return int(font.getlength(text))
    if hasattr(font, "getsize"):
        return int(font.getsize(text)[0])
    return len(text) * 7  # crude fallback


def _wrap(text, width, font_size, margin):
    """Word-wrap ``text`` to lines fitting in ``width`` pixels under a
    rough character-width estimate.

    Verbatim from ``node_types/list_renderer.py:_wrap``. Yields one
    wrapped line per iteration; callers compose into draw.text() calls.
    The character-width estimate (``font_size // 2``) is a heuristic;
    the rendered output uses ``_measure`` for exact pixel widths when it
    matters (e.g., truncation).
    """
    max_chars = max(10, (width - 2 * margin) // (font_size // 2))
    line = ""
    for word in text.split(" "):
        if not line:
            line = word
        elif len(line) + 1 + len(word) <= max_chars:
            line += " " + word
        else:
            yield line
            line = word
    if line:
        yield line


def _wrap_line(line: str, max_chars: int):
    """Wrap one source line to ``max_chars``-width fragments.

    Verbatim from ``node_types/chat_interface.py:_wrap_line``. Distinct
    from ``_wrap`` in that this version takes a pre-computed
    ``max_chars`` (rather than computing one from width + font_size +
    margin) and short-circuits when the line already fits. Both wrappers
    are kept because both call sites exist in the codebase verbatim;
    consolidating to one is a follow-up tidy that risks subtle
    behavioral diffs.
    """
    if len(line) <= max_chars:
        yield line
        return
    words = line.split(" ")
    cur = ""
    for w in words:
        if not cur:
            cur = w
        elif len(cur) + 1 + len(w) <= max_chars:
            cur = cur + " " + w
        else:
            yield cur
            cur = w
    if cur:
        yield cur


def _truncate(text, max_w, font) -> str:
    """Truncate ``text`` to fit ``max_w`` pixels, suffixing with ``…``.

    Verbatim from ``node_types/list_renderer.py:_truncate``. Linear
    scan from full length downward; the first candidate that fits is
    returned. Returns empty string when even the suffix exceeds
    ``max_w`` (rare; defensive).
    """
    for i in range(len(text), 0, -1):
        candidate = text[:i] + "…"
        if _measure(candidate, font) <= max_w:
            return candidate
    return ""


# ---------------------------------------------------------------------------
# Text → numpy array rendering
# ---------------------------------------------------------------------------


def _render_text_to_array(text: str, width: int, height: int, font_size: int,
                          text_color: np.ndarray, background_color: np.ndarray) -> np.ndarray:
    """Render ``text`` to an RGB numpy array of shape (height, width, 3)
    in [0, 1].

    Verbatim from ``node_types/chat_interface.py:_render_text_to_array``.
    Word-wraps via ``_wrap_line`` (the chat-interface convention; line-
    oriented), draws line-by-line, returns float32 normalized.
    """
    bg = tuple(int(c * 255) for c in background_color)
    fg = tuple(int(c * 255) for c in text_color)
    img = Image.new("RGB", (width, height), color=bg)
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)

    margin = max(4, font_size // 3)
    line_height = font_size + 4
    max_chars_per_line = max(10, (width - 2 * margin) // (font_size // 2))

    y = margin
    for raw_line in text.splitlines():
        # Soft-wrap long lines
        for piece in _wrap_line(raw_line, max_chars_per_line):
            if y + line_height > height - margin:
                break
            draw.text((margin, y), piece, fill=fg, font=font)
            y += line_height
        if y + line_height > height - margin:
            break

    arr = np.asarray(img, dtype=np.float32) / 255.0
    return arr


# ---------------------------------------------------------------------------
# Screen-rectangle paste (ray-cast + UV-sample)
# ---------------------------------------------------------------------------


def _paste_onto_screen_rectangle(view: View, screen_w: float, screen_h: float,
                                 internal_color: np.ndarray) -> Channels:
    """Ray-cast the outer view against a screen rectangle in the XY
    plane at z=0; UV-sample ``internal_color`` onto inside-screen pixels.

    Verbatim from ``node_types/list_renderer.py:_paste_onto_screen_rectangle``
    (the canonical form; ``chat_interface.py`` ships a byte-identical
    copy). The function signature is ``(view, screen_w, screen_h,
    internal_color) -> {"color", "depth"}``. Outside-screen pixels
    return zero color + infinite depth so other geometry composites
    through naturally.

    The 3D-paste primitive: a 2D image (RGB numpy array in [0, 1])
    appears as the content of a planar screen-rectangle in the outer 3D
    scene. Brief 03's BoxNode + TextBoxNode + all surface primitives
    compose against this — no per-primitive ray-cast code needed.
    """
    out_w, out_h = view.width, view.height
    half_h = np.tan(view.fov_y_radians / 2)
    half_w_view = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, out_w) * half_w_view
    ys = np.linspace(1.0, -1.0, out_h) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)
    dirs_world = dirs_cam @ view.orientation.T

    origin = view.position
    eps = 1e-9
    safe_dz = np.where(np.abs(dirs_world[..., 2]) < eps,
                       eps * np.sign(dirs_world[..., 2] + eps),
                       dirs_world[..., 2])
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (t > 0) & (np.abs(x_hit) <= screen_w / 2.0) & (np.abs(y_hit) <= screen_h / 2.0)

    color_out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    depth_out = np.full((out_h, out_w), np.inf, dtype=np.float32)

    int_h, int_w = internal_color.shape[:2]
    u = (x_hit + screen_w / 2.0) / screen_w
    v = 1.0 - (y_hit + screen_h / 2.0) / screen_h
    sample_x = np.clip((u * int_w).astype(int), 0, int_w - 1)
    sample_y = np.clip((v * int_h).astype(int), 0, int_h - 1)
    sampled = internal_color[sample_y, sample_x]
    color_out = np.where(inside[..., None], sampled, color_out)
    depth_out = np.where(inside, t.astype(np.float32), depth_out)

    return {"color": color_out, "depth": depth_out}


# ---------------------------------------------------------------------------
# Layer-ordering conflict resolution (Decision A5 / SPEC-094)
# ---------------------------------------------------------------------------
#
# Brief 03 commit 2 ships this helper alongside BoxNode/TextBoxNode/
# ToolboxNode per the per-module plan's N-F028 module-spec step 2:
# "Add a `_resolve_layer_conflicts()` helper in `engine/screen.py` that
# runs the auto-reflow algorithm before emit."
#
# Algorithm per Decision A5:
#   1. Sort primitives by insertion order (the input list IS the
#      insertion order — earlier indices = earlier inserts).
#   2. For each primitive, in order: detect overlap with any
#      already-placed primitive on the SAME LAYER. If overlap is
#      detected, attempt to relocate via a brute-force grid scan
#      within `parent_bounds` (the auto-reflow). If no non-overlapping
#      position fits within parent_bounds, bump the primitive's layer
#      to `max(layer + 1, max_layer_so_far + 1)` (the layer-bump
#      fallback).
#   3. Composes against the same overlap math
#      PanelPositioner.snap_to_peers uses (Apeiron
#      `node_types/panel_positioner.py:_compute_peer_snap`); the
#      bounding-box overlap check is the same shape.
#
# The helper is pure: takes records in, returns adjusted records +
# diagnostics (the SAME records when nothing changed, supporting the
# idempotent-on-already-resolved-input contract that the renderer
# pipeline can call this before every emit without paying for
# duplicate work).


def _bbox_overlaps(a: Dict[str, Any], b: Dict[str, Any]) -> bool:
    """Axis-aligned bounding-box overlap test (open interval).

    Two boxes overlap when their projections on both axes overlap. Edge-
    sharing (a.x + a.w == b.x) is treated as NOT overlapping so adjacent
    placement is permitted per the maintainer's "next to each other"
    framing of N-F028.
    """
    ax1, ay1 = float(a["x"]), float(a["y"])
    ax2, ay2 = ax1 + float(a["w"]), ay1 + float(a["h"])
    bx1, by1 = float(b["x"]), float(b["y"])
    bx2, by2 = bx1 + float(b["w"]), by1 + float(b["h"])
    return (ax1 < bx2) and (bx1 < ax2) and (ay1 < by2) and (by1 < ay2)


def _find_non_overlapping_position(
    record: Dict[str, Any],
    placed: list,
    parent_bounds: Dict[str, float],
    grid_px: int,
) -> Dict[str, float]:
    """Brute-force grid scan for a non-overlapping (x, y) within
    parent_bounds for ``record`` against the already-placed list (same
    layer only — caller filters).

    Returns the new (x, y) when a slot is found; returns the
    sentinel ``{"x": -1.0, "y": -1.0}`` when no slot fits (caller
    handles via layer-bump per Decision A5).

    The scan walks rows top-to-bottom, columns left-to-right — the
    insertion-order-preserving heuristic the maintainer's directive
    implies (later-inserted lands wherever the earlier ones leave a
    gap, not flips the earlier-inserted around).
    """
    px_min = float(parent_bounds.get("x_min", 0.0))
    py_min = float(parent_bounds.get("y_min", 0.0))
    px_max = float(parent_bounds.get("x_max", 0.0))
    py_max = float(parent_bounds.get("y_max", 0.0))
    w = float(record["w"])
    h = float(record["h"])
    grid = max(1, int(grid_px))

    y = py_min
    while y + h <= py_max + 1e-9:
        x = px_min
        while x + w <= px_max + 1e-9:
            candidate = {"x": x, "y": y, "w": w, "h": h}
            if not any(_bbox_overlaps(candidate, p) for p in placed):
                return {"x": x, "y": y}
            x += grid
        y += grid
    return {"x": -1.0, "y": -1.0}


def _resolve_layer_conflicts(
    records: list,
    parent_bounds: Optional[Dict[str, float]] = None,
    grid_px: int = 12,
) -> Dict[str, Any]:
    """Resolve same-layer overlap via auto-reflow + layer-bump fallback.

    ``records`` is a list of dicts with at minimum these fields::

        {"id": <str>, "x": <float>, "y": <float>,
         "w": <float>, "h": <float>, "layer": <int>}

    Additional fields (e.g., ``corner_radius``, ``displayed_by``) pass
    through untouched. The function preserves input order — the list
    index IS the insertion order; earlier indices are placed first
    (they stay; later ones move).

    ``parent_bounds`` defaults to ``{"x_min": 0, "y_min": 0,
    "x_max": 10000, "y_max": 10000}`` — a generous default so simple
    test cases don't have to specify bounds. Surface integrations
    (workflow surface, GUI builder) pass real bounds.

    Returns ``{"records": [adjusted_records...],
    "diagnostics": {"reflow_count": N, "layer_bump_count": M,
    "moved_ids": [...], "bumped_ids": [...], "final_max_layer": L}}``.
    Idempotent: a second call on the returned records produces the
    same records + zero counts.
    """
    if parent_bounds is None:
        parent_bounds = {
            "x_min": 0.0, "y_min": 0.0,
            "x_max": 10000.0, "y_max": 10000.0,
        }

    adjusted: list = []
    reflow_count = 0
    layer_bump_count = 0
    moved_ids: list = []
    bumped_ids: list = []

    for record in records:
        if not isinstance(record, dict):
            adjusted.append(record)
            continue
        # Copy so we don't mutate the input. Pass-through unknown fields.
        cur = dict(record)
        layer = int(cur.get("layer", 0))

        # Same-layer placed records (from the adjusted list, after any
        # earlier bumps). Reading from `adjusted` (not `records`) lets
        # bumped-earlier records be considered at their NEW layer.
        peers = [p for p in adjusted
                 if isinstance(p, dict) and int(p.get("layer", 0)) == layer]
        # If no overlap, accept as-is.
        if not any(_bbox_overlaps(cur, p) for p in peers):
            adjusted.append(cur)
            continue

        # Same-layer collision — try auto-reflow first.
        new_pos = _find_non_overlapping_position(cur, peers, parent_bounds, grid_px)
        if new_pos["x"] >= 0.0 and new_pos["y"] >= 0.0:
            if new_pos["x"] != cur["x"] or new_pos["y"] != cur["y"]:
                reflow_count += 1
                rec_id = cur.get("id")
                if rec_id is not None:
                    moved_ids.append(rec_id)
                cur["x"] = new_pos["x"]
                cur["y"] = new_pos["y"]
            adjusted.append(cur)
            continue

        # Auto-reflow exhausted — layer-bump per Decision A5.
        max_layer_so_far = max(
            (int(p.get("layer", 0)) for p in adjusted if isinstance(p, dict)),
            default=layer,
        )
        new_layer = max(layer + 1, max_layer_so_far + 1)
        cur["layer"] = new_layer
        layer_bump_count += 1
        rec_id = cur.get("id")
        if rec_id is not None:
            bumped_ids.append(rec_id)
        adjusted.append(cur)

    final_max_layer = max(
        (int(p.get("layer", 0)) for p in adjusted if isinstance(p, dict)),
        default=0,
    )

    return {
        "records": adjusted,
        "diagnostics": {
            "reflow_count": reflow_count,
            "layer_bump_count": layer_bump_count,
            "moved_ids": moved_ids,
            "bumped_ids": bumped_ids,
            "final_max_layer": final_max_layer,
        },
    }


# ---------------------------------------------------------------------------
# __all__ — re-exports for the call sites
# ---------------------------------------------------------------------------

__all__ = [
    "_get_font",
    "_measure",
    "_wrap",
    "_wrap_line",
    "_truncate",
    "_render_text_to_array",
    "_paste_onto_screen_rectangle",
    "_resolve_layer_conflicts",
    "_bbox_overlaps",
]
