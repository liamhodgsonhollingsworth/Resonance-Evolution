"""Tests for layer-ordering + same-layer auto-reflow (SPEC-094 /
Decision A5).

Brief 03 commit 2 — exercises the ``_resolve_layer_conflicts`` helper
added to ``engine/screen.py`` per the per-module plan's N-F028 module-
spec step 2. The helper is a pure function that takes a list of
primitive bounding boxes + their layers and returns the same list with
adjusted positions / layers per Decision A5:

  1. Same-layer overlap → auto-reflow (move the LATER-INSERTED one).
  2. Reflow exhausted → layer-bump (later primitive jumps to
     max(layer + 1, max_layer_so_far + 1)).
  3. Different-layer overlaps are PERMITTED (z-order does the right
     thing).

Per Scenario 6 of the per-module plan: *"Create two BoxNodes on layer 0
at overlapping positions. Render. PASS if the later-inserted box
auto-reflows to non-overlapping position OR bumps to layer 1; collision
count in debug overlay = 1."*
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine.screen import _bbox_overlaps, _resolve_layer_conflicts  # noqa: E402


# ---------- bbox overlap predicate ----------


def test_bbox_overlaps_identical():
    a = {"x": 0, "y": 0, "w": 100, "h": 100}
    b = {"x": 0, "y": 0, "w": 100, "h": 100}
    assert _bbox_overlaps(a, b) is True


def test_bbox_overlaps_partial():
    a = {"x": 0, "y": 0, "w": 100, "h": 100}
    b = {"x": 50, "y": 50, "w": 100, "h": 100}
    assert _bbox_overlaps(a, b) is True


def test_bbox_overlaps_disjoint():
    a = {"x": 0, "y": 0, "w": 100, "h": 100}
    b = {"x": 200, "y": 0, "w": 100, "h": 100}
    assert _bbox_overlaps(a, b) is False


def test_bbox_overlaps_edge_sharing_treated_as_non_overlap():
    """Adjacent boxes (sharing an edge) are NOT overlapping — they are
    "next to each other" per the maintainer's N-F028 framing."""
    a = {"x": 0, "y": 0, "w": 100, "h": 100}
    b = {"x": 100, "y": 0, "w": 100, "h": 100}
    assert _bbox_overlaps(a, b) is False


def test_bbox_overlaps_one_inside_other():
    a = {"x": 0, "y": 0, "w": 100, "h": 100}
    b = {"x": 25, "y": 25, "w": 50, "h": 50}
    assert _bbox_overlaps(a, b) is True


# ---------- _resolve_layer_conflicts: no-op cases ----------


def test_resolve_empty_input():
    out = _resolve_layer_conflicts([])
    assert out["records"] == []
    assert out["diagnostics"]["reflow_count"] == 0
    assert out["diagnostics"]["layer_bump_count"] == 0


def test_resolve_single_box_no_op():
    records = [{"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0}]
    out = _resolve_layer_conflicts(records)
    assert out["records"] == records
    assert out["diagnostics"]["reflow_count"] == 0


def test_resolve_already_disjoint_same_layer_no_op():
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 200, "y": 0, "w": 100, "h": 100, "layer": 0},
    ]
    out = _resolve_layer_conflicts(records)
    assert out["records"] == records
    assert out["diagnostics"]["reflow_count"] == 0
    assert out["diagnostics"]["layer_bump_count"] == 0


def test_resolve_overlap_on_different_layers_no_op():
    """Different layers can overlap freely (z-order resolves)."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 50, "y": 50, "w": 100, "h": 100, "layer": 1},
    ]
    out = _resolve_layer_conflicts(records)
    assert out["records"][0]["x"] == 0  # unchanged
    assert out["records"][1]["x"] == 50  # unchanged
    assert out["diagnostics"]["reflow_count"] == 0


# ---------- _resolve_layer_conflicts: reflow ----------


def test_resolve_two_overlapping_boxes_reflows_later(tmp_path):
    """Scenario 6: two BoxNodes on layer 0 at overlapping positions.
    The later-inserted one (insertion-order tiebreak) moves."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 50, "y": 50, "w": 100, "h": 100, "layer": 0},
    ]
    out = _resolve_layer_conflicts(records, parent_bounds={
        "x_min": 0, "y_min": 0, "x_max": 500, "y_max": 500,
    })
    # "a" unchanged.
    assert out["records"][0]["x"] == 0
    assert out["records"][0]["y"] == 0
    # "b" moved to a non-overlapping position.
    assert not _bbox_overlaps(out["records"][0], out["records"][1])
    assert out["diagnostics"]["reflow_count"] == 1
    assert "b" in out["diagnostics"]["moved_ids"]


def test_resolve_three_overlapping_boxes_reflow_two():
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 50, "h": 50, "layer": 0},
        {"id": "b", "x": 10, "y": 10, "w": 50, "h": 50, "layer": 0},
        {"id": "c", "x": 20, "y": 20, "w": 50, "h": 50, "layer": 0},
    ]
    out = _resolve_layer_conflicts(records, parent_bounds={
        "x_min": 0, "y_min": 0, "x_max": 1000, "y_max": 1000,
    })
    # All three should end up disjoint on the same layer.
    placed = out["records"]
    for i in range(len(placed)):
        for j in range(i + 1, len(placed)):
            assert not _bbox_overlaps(placed[i], placed[j])
    assert out["diagnostics"]["reflow_count"] == 2


# ---------- _resolve_layer_conflicts: layer-bump fallback ----------


def test_resolve_exhausted_bounds_triggers_layer_bump():
    """When parent_bounds can't fit a non-overlapping position, the
    later primitive's layer bumps to layer + 1 (Decision A5 last
    resort)."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
    ]
    # parent_bounds exactly fit one box — no room to reflow.
    out = _resolve_layer_conflicts(records, parent_bounds={
        "x_min": 0, "y_min": 0, "x_max": 100, "y_max": 100,
    })
    assert out["records"][0]["layer"] == 0
    assert out["records"][1]["layer"] == 1
    assert out["diagnostics"]["layer_bump_count"] == 1
    assert "b" in out["diagnostics"]["bumped_ids"]
    assert out["diagnostics"]["final_max_layer"] == 1


def test_resolve_cascade_layer_bump():
    """Three identical boxes in identical positions with tight bounds
    cascade to layers 0, 1, 2."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "c", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
    ]
    out = _resolve_layer_conflicts(records, parent_bounds={
        "x_min": 0, "y_min": 0, "x_max": 100, "y_max": 100,
    })
    layers = [r["layer"] for r in out["records"]]
    assert layers == [0, 1, 2]
    assert out["diagnostics"]["layer_bump_count"] == 2


# ---------- _resolve_layer_conflicts: idempotency ----------


def test_resolve_idempotent_on_already_resolved_records():
    """Running the helper on its own output produces the same output."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 200, "y": 0, "w": 100, "h": 100, "layer": 0},
    ]
    out1 = _resolve_layer_conflicts(records)
    out2 = _resolve_layer_conflicts(out1["records"])
    assert out1["records"] == out2["records"]
    assert out2["diagnostics"]["reflow_count"] == 0
    assert out2["diagnostics"]["layer_bump_count"] == 0


def test_resolve_diagnostics_record_moved_ids_only_when_moved():
    """A reflow that returns the same position (already disjoint) should
    NOT record the id as moved."""
    records = [
        {"id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "layer": 0},
        {"id": "b", "x": 200, "y": 200, "w": 100, "h": 100, "layer": 0},
    ]
    out = _resolve_layer_conflicts(records)
    assert out["diagnostics"]["moved_ids"] == []
    assert out["diagnostics"]["bumped_ids"] == []


# ---------- BoxNode integration ----------


def test_box_nodes_carry_layer_field():
    """BoxNode honors the layer field — the input to the
    resolve_layer_conflicts pipeline. Tested via the primitive's
    build output."""
    import sys
    sys.path.insert(0, str(ROOT))
    from engine import Engine
    e = Engine(root_dir=ROOT)
    e.discover()
    e.spawn("box_layer", "BoxNode", params={"layer": 4})
    assert e.nodes["box_layer"].state["layer"] == 4
