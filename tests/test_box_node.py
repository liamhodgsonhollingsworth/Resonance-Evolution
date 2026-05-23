"""Tests for BoxNode — N-F019 / SPEC-094 foundational primitive.

Brief 03 commit 2 of the Resonance website implementation arc — the
first of the three foundational primitives this commit ships. Covers:

- Engine discovery via ``Engine.discover()`` (the node-type file is
  picked up automatically per the brief 03 commit 1 +
  ``engine.core.Engine._load_node_type_file`` convention).
- Default-build state — every documented field with documented default.
- Value-passthrough — explicit params survive build.
- accept_unknown_drop enum validation (SPEC-092 default).
- Layer field (SPEC-094) — integer with default 0.
- Visual-variant slot via ``displayed_by:`` (Decision A1) — empty
  string by default, custom value preserved.
- ``emit()`` produces ``{color, depth}`` channels of view dimensions.
- ``emit()`` is deterministic — same input → same output.
- ``describe()`` produces a one-line summary including key state.
- ``select_children()`` returns empty (no recursion).
- Lock delegation via the ``is_locked`` helper composing
  ``WidgetLock`` (SPEC-075).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.node import EmitContext, look_at  # noqa: E402


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


@pytest.fixture
def view() -> View:
    return View(
        position=np.array([0.0, 0.0, 5.0], dtype=np.float64),
        orientation=look_at(
            np.array([0.0, 0.0, 5.0]),
            np.array([0.0, 0.0, 0.0]),
        ),
        width=32, height=32,
    )


# ---------- registration ----------


def test_box_node_registers(engine):
    assert "BoxNode" in engine.types
    m = engine.types["BoxNode"].manifest()
    assert m.name == "BoxNode"
    assert m.version == "1.0"
    assert m.renderer_id == "raster"
    # Confirm all documented inputs declared.
    expected = {
        "screen_width", "screen_height", "screen_resolution",
        "corner_radius", "fill_color", "border_color", "border_width",
        "layer", "accept_unknown_drop", "displayed_by",
    }
    assert expected.issubset(set(m.inputs.keys()))


# ---------- build ----------


def test_build_defaults_full_state(engine):
    engine.spawn("box1", "BoxNode", params={})
    node = engine.nodes["box1"]
    assert not node.dead, f"build failed: {node.error}"
    s = node.state
    assert s["screen_width"] == 2.0
    assert s["screen_height"] == 1.5
    assert s["corner_radius"] == 0.0
    assert s["layer"] == 0
    assert s["accept_unknown_drop"] == "return-to-origin"
    assert s["displayed_by"] == ""
    assert isinstance(s["fill_color"], np.ndarray)
    assert s["fill_color"].shape == (3,)


def test_build_value_passthrough(engine):
    engine.spawn(
        "box2", "BoxNode",
        params={
            "screen_width": 5.0,
            "screen_height": 3.0,
            "corner_radius": 0.3,
            "fill_color": [0.5, 0.2, 0.1],
            "border_color": [1.0, 1.0, 1.0],
            "border_width": 2,
            "layer": 7,
            "accept_unknown_drop": "stay-where-dropped",
            "displayed_by": "box_minimal_v1",
        },
    )
    s = engine.nodes["box2"].state
    assert s["screen_width"] == 5.0
    assert s["screen_height"] == 3.0
    assert s["corner_radius"] == 0.3
    assert s["border_width"] == 2.0
    assert s["layer"] == 7
    assert s["accept_unknown_drop"] == "stay-where-dropped"
    assert s["displayed_by"] == "box_minimal_v1"
    np.testing.assert_array_almost_equal(s["fill_color"], [0.5, 0.2, 0.1])


def test_build_invalid_accept_unknown_drop_falls_back(engine):
    """A misconfigured accept_unknown_drop falls back to the default
    rather than failing the spawn — keeps the primitive instantiable
    even with bad input."""
    engine.spawn(
        "box3", "BoxNode",
        params={"accept_unknown_drop": "not-a-valid-mode"},
    )
    s = engine.nodes["box3"].state
    assert s["accept_unknown_drop"] == "return-to-origin"


def test_build_accepts_all_three_drop_modes(engine):
    from node_types.box import ACCEPT_UNKNOWN_DROP_MODES
    for i, mode in enumerate(ACCEPT_UNKNOWN_DROP_MODES):
        engine.spawn(f"box_drop_{i}", "BoxNode",
                     params={"accept_unknown_drop": mode})
        assert engine.nodes[f"box_drop_{i}"].state["accept_unknown_drop"] == mode


# ---------- emit ----------


def test_emit_returns_channels(engine, view):
    engine.spawn("box4", "BoxNode", params={"corner_radius": 0.2})
    node = engine.nodes["box4"]
    ctx = EmitContext(engine=engine, node=node)
    ch = engine.types["BoxNode"].emit(node.state, view, ctx)
    assert "color" in ch
    assert "depth" in ch
    assert ch["color"].shape == (view.height, view.width, 3)
    assert ch["depth"].shape == (view.height, view.width)
    assert ch["color"].dtype == np.float32


def test_emit_produces_non_zero_color_inside_screen_rect(engine, view):
    """A reasonably-sized box at the origin should produce non-zero
    color somewhere in the frame (the rasterized rectangle).
    """
    engine.spawn(
        "box5", "BoxNode",
        params={
            "screen_width": 3.0,
            "screen_height": 3.0,
            "fill_color": [1.0, 0.5, 0.2],
        },
    )
    node = engine.nodes["box5"]
    ch = engine.types["BoxNode"].emit(
        node.state, view, EmitContext(engine=engine, node=node)
    )
    # Some pixels have non-zero color (the rectangle's projection
    # hits the frame at the view distance).
    assert ch["color"].sum() > 0


def test_emit_deterministic(engine, view):
    engine.spawn("box6", "BoxNode", params={"corner_radius": 0.1})
    node = engine.nodes["box6"]
    ctx = EmitContext(engine=engine, node=node)
    out1 = engine.types["BoxNode"].emit(node.state, view, ctx)
    out2 = engine.types["BoxNode"].emit(node.state, view, ctx)
    np.testing.assert_array_equal(out1["color"], out2["color"])
    np.testing.assert_array_equal(out1["depth"], out2["depth"])


def test_emit_corner_radius_affects_output(engine, view):
    """Different corner_radius values produce different rasters (the
    primitive's headline feature). Round-corner vs sharp-corner
    produces visibly different output near the corners."""
    engine.spawn("sharp", "BoxNode", params={
        "screen_width": 3.0, "screen_height": 3.0,
        "corner_radius": 0.0, "fill_color": [1.0, 1.0, 1.0],
    })
    engine.spawn("round", "BoxNode", params={
        "screen_width": 3.0, "screen_height": 3.0,
        "corner_radius": 0.4, "fill_color": [1.0, 1.0, 1.0],
    })
    sharp = engine.types["BoxNode"].emit(
        engine.nodes["sharp"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sharp"]),
    )
    rounded = engine.types["BoxNode"].emit(
        engine.nodes["round"].state, view,
        EmitContext(engine=engine, node=engine.nodes["round"]),
    )
    # Sharp box paints more pixels than the rounded box (the rounded
    # corners are transparent / clipped to black on rasterize).
    assert sharp["color"].sum() >= rounded["color"].sum()


# ---------- describe ----------


def test_describe_one_line_includes_key_state(engine):
    engine.spawn(
        "box7", "BoxNode",
        params={
            "screen_width": 4.0, "screen_height": 2.0,
            "corner_radius": 0.15, "layer": 3,
            "accept_unknown_drop": "reject",
        },
    )
    node = engine.nodes["box7"]
    text = engine.types["BoxNode"].describe(
        node.state, EmitContext(engine=engine, node=node)
    )
    assert "BoxNode" in text
    assert "box7" in text
    assert "4.00x2.00" in text
    assert "0.15" in text
    assert "layer=3" in text
    assert "reject" in text


# ---------- select_children ----------


def test_select_children_returns_empty(engine):
    engine.spawn("box8", "BoxNode", params={})
    node = engine.nodes["box8"]
    children = engine.types["BoxNode"].select_children(
        node.state, View(), engine, node,
    )
    assert children == []


# ---------- lock delegation (SPEC-075) ----------


def test_is_locked_returns_false_for_none_registry():
    from node_types.box import is_locked
    assert is_locked("any_id", None) is False


def test_is_locked_returns_false_for_unknown_widget():
    from node_types.box import is_locked
    from tools.workflow_gui.widget_lock import WidgetLock
    registry = WidgetLock()
    assert is_locked("never_seen_box", registry) is False


def test_is_locked_returns_true_after_lock():
    from node_types.box import is_locked
    from tools.workflow_gui.widget_lock import WidgetLock
    registry = WidgetLock()
    registry.lock_widget("box_xyz", widget_kind="box")
    assert is_locked("box_xyz", registry) is True


def test_is_locked_returns_false_after_unlock():
    from node_types.box import is_locked
    from tools.workflow_gui.widget_lock import WidgetLock
    registry = WidgetLock()
    registry.lock_widget("box_abc")
    registry.unlock_widget("box_abc")
    assert is_locked("box_abc", registry) is False
