"""Tests for ScrollBarNode — N-F023 / SPEC-090 functional primitive.

Brief 03 commit 3. Covers:

- Engine discovery via ``Engine.discover()``.
- Default-build state (every documented field with default).
- Value-passthrough — explicit params survive build.
- Value clamping at build-time + on set_value.
- Orientation enum validation.
- Min/max swap when max < min (defensive).
- emit() produces channels of view dimensions.
- emit() responds to different value — different output.
- emit() deterministic.
- describe() one-line, includes key state.
- handle_action verbs: set_value (clamping, success delta),
  get_value, unknown action returns None.
- displayed_by slot — empty default, custom string preserved.
- accept_unknown_drop semantics inherited from BoxNode are NOT
  applicable to scroll-bars (they're drop SOURCES not targets in the
  scroll-bar-onto-text-box interaction).
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
        width=32, height=64,
    )


# ---------- registration ----------


def test_scroll_bar_node_registers(engine):
    assert "ScrollBarNode" in engine.types
    m = engine.types["ScrollBarNode"].manifest()
    assert m.name == "ScrollBarNode"
    assert m.version == "1.0"
    assert m.renderer_id == "raster"
    expected = {
        "screen_width", "screen_height", "screen_resolution",
        "min", "max", "value", "orientation", "connected_to",
        "layer", "displayed_by", "track_color", "thumb_color",
    }
    assert expected.issubset(set(m.inputs.keys()))


# ---------- build ----------


def test_build_defaults_full_state(engine):
    engine.spawn("sb1", "ScrollBarNode", params={})
    n = engine.nodes["sb1"]
    assert not n.dead, f"build failed: {n.error}"
    s = n.state
    assert s["min"] == 0.0
    assert s["max"] == 1.0
    assert s["value"] == 0.0
    assert s["orientation"] == "vertical"
    assert s["connected_to"] == ""
    assert s["layer"] == 0
    assert s["displayed_by"] == ""


def test_build_value_passthrough(engine):
    engine.spawn(
        "sb2", "ScrollBarNode",
        params={
            "min": 0.0, "max": 100.0, "value": 42.0,
            "orientation": "horizontal",
            "connected_to": "text_box_main",
            "layer": 3,
            "displayed_by": "scroll_bar_chunky_v1",
            "track_color": [0.4, 0.4, 0.4],
            "thumb_color": [0.9, 0.9, 0.9],
        },
    )
    s = engine.nodes["sb2"].state
    assert s["min"] == 0.0
    assert s["max"] == 100.0
    assert s["value"] == 42.0
    assert s["orientation"] == "horizontal"
    assert s["connected_to"] == "text_box_main"
    assert s["layer"] == 3
    assert s["displayed_by"] == "scroll_bar_chunky_v1"
    np.testing.assert_array_almost_equal(s["track_color"], [0.4, 0.4, 0.4])


def test_build_clamps_value_to_range(engine):
    """Value above max is clamped to max; below min clamped to min."""
    engine.spawn("sb_high", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0, "value": 5.0})
    assert engine.nodes["sb_high"].state["value"] == 1.0

    engine.spawn("sb_low", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0, "value": -2.0})
    assert engine.nodes["sb_low"].state["value"] == 0.0


def test_build_invalid_orientation_falls_back(engine):
    engine.spawn("sb_o", "ScrollBarNode",
                 params={"orientation": "diagonal"})
    assert engine.nodes["sb_o"].state["orientation"] == "vertical"


def test_build_max_less_than_min_swaps(engine):
    """max < min is defensive: swap rather than crash."""
    engine.spawn("sb_sw", "ScrollBarNode",
                 params={"min": 10.0, "max": 2.0, "value": 5.0})
    s = engine.nodes["sb_sw"].state
    assert s["min"] == 2.0
    assert s["max"] == 10.0
    assert s["value"] == 5.0


# ---------- emit ----------


def test_emit_returns_channels(engine, view):
    engine.spawn("sb4", "ScrollBarNode", params={"value": 0.5})
    n = engine.nodes["sb4"]
    ch = engine.types["ScrollBarNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert "color" in ch and "depth" in ch
    assert ch["color"].shape == (view.height, view.width, 3)
    assert ch["color"].dtype == np.float32


def test_emit_different_value_different_output(engine, view):
    """Different value values produce different thumb positions →
    different rendered output."""
    engine.spawn("sb_lo", "ScrollBarNode", params={"value": 0.0})
    engine.spawn("sb_hi", "ScrollBarNode", params={"value": 1.0})
    lo = engine.types["ScrollBarNode"].emit(
        engine.nodes["sb_lo"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sb_lo"]),
    )
    hi = engine.types["ScrollBarNode"].emit(
        engine.nodes["sb_hi"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sb_hi"]),
    )
    assert not np.array_equal(lo["color"], hi["color"])


def test_emit_deterministic(engine, view):
    engine.spawn("sb_det", "ScrollBarNode", params={"value": 0.42})
    n = engine.nodes["sb_det"]
    ctx = EmitContext(engine=engine, node=n)
    a = engine.types["ScrollBarNode"].emit(n.state, view, ctx)
    b = engine.types["ScrollBarNode"].emit(n.state, view, ctx)
    np.testing.assert_array_equal(a["color"], b["color"])


def test_emit_horizontal_vs_vertical_differ(engine, view):
    engine.spawn("sb_h", "ScrollBarNode",
                 params={"value": 0.5, "orientation": "horizontal",
                         "screen_width": 2.0, "screen_height": 0.4})
    engine.spawn("sb_v", "ScrollBarNode",
                 params={"value": 0.5, "orientation": "vertical",
                         "screen_width": 0.4, "screen_height": 2.0})
    h = engine.types["ScrollBarNode"].emit(
        engine.nodes["sb_h"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sb_h"]),
    )
    v = engine.types["ScrollBarNode"].emit(
        engine.nodes["sb_v"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sb_v"]),
    )
    assert not np.array_equal(h["color"], v["color"])


# ---------- describe ----------


def test_describe_one_line_includes_state(engine):
    engine.spawn("sb_d", "ScrollBarNode",
                 params={"min": 0.0, "max": 100.0, "value": 25.0,
                         "orientation": "horizontal",
                         "connected_to": "main_text"})
    n = engine.nodes["sb_d"]
    text = engine.types["ScrollBarNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "ScrollBarNode" in text
    assert "sb_d" in text
    assert "25.000" in text
    assert "horizontal" in text
    assert "main_text" in text


# ---------- handle_action ----------


def _dispatch(engine, node_id, verb, payload=None):
    n = engine.nodes[node_id]
    return engine.types["ScrollBarNode"].handle_action(
        n.state, verb, payload or {}, engine, n,
    )


def test_set_value_persists(engine):
    engine.spawn("sb_sv", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0, "value": 0.0})
    d = _dispatch(engine, "sb_sv", "set_value", {"value": 0.75})
    assert d["last_set_value"]["set"] is True
    assert d["last_set_value"]["value"] == 0.75
    assert engine.nodes["sb_sv"].state["value"] == 0.75


def test_set_value_clamps(engine):
    engine.spawn("sb_clamp", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0})
    d = _dispatch(engine, "sb_clamp", "set_value", {"value": 2.0})
    assert d["last_set_value"]["set"] is True
    assert d["last_set_value"]["clamped"] is True
    assert d["last_set_value"]["value"] == 1.0
    assert engine.nodes["sb_clamp"].state["value"] == 1.0


def test_set_value_invalid_value(engine):
    engine.spawn("sb_bad", "ScrollBarNode", params={})
    d = _dispatch(engine, "sb_bad", "set_value", {"value": "not a number"})
    assert d["last_set_value"]["set"] is False


def test_get_value_reads_back(engine):
    engine.spawn("sb_gv", "ScrollBarNode", params={"value": 0.3})
    d = _dispatch(engine, "sb_gv", "get_value")
    assert d["value"] == 0.3


def test_unknown_action_returns_none(engine):
    engine.spawn("sb_u", "ScrollBarNode", params={})
    n = engine.nodes["sb_u"]
    out = engine.types["ScrollBarNode"].handle_action(
        n.state, "nonexistent", {}, engine, n,
    )
    assert out is None


# ---------- displayed_by slot ----------


def test_displayed_by_default_empty(engine):
    engine.spawn("sb_dx", "ScrollBarNode", params={})
    assert engine.nodes["sb_dx"].state["displayed_by"] == ""


def test_displayed_by_custom_preserved(engine):
    engine.spawn("sb_dx2", "ScrollBarNode",
                 params={"displayed_by": "scroll_bar_chunky_v1"})
    assert engine.nodes["sb_dx2"].state["displayed_by"] == "scroll_bar_chunky_v1"
