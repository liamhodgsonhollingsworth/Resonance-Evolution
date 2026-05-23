"""Tests for SliderNode — N-F025 / SPEC-090 functional primitive.

Brief 03 commit 3. Covers registration, build defaults + value
passthrough, value clamping + step snapping, set_value / get_value /
step_up / step_down verb dispatch, emit responding to value changes,
describe content + displayed_by slot.
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
        width=64, height=32,
    )


def test_slider_node_registers(engine):
    assert "SliderNode" in engine.types
    m = engine.types["SliderNode"].manifest()
    assert m.name == "SliderNode"
    expected = {
        "min", "max", "value", "step", "orientation",
        "parameter_target", "layer", "displayed_by",
    }
    assert expected.issubset(set(m.inputs.keys()))


def test_build_defaults(engine):
    engine.spawn("sl1", "SliderNode", params={})
    s = engine.nodes["sl1"].state
    assert s["min"] == 0.0
    assert s["max"] == 1.0
    assert s["value"] == 0.0
    assert s["step"] == 0.01
    assert s["orientation"] == "horizontal"
    assert s["parameter_target"] == ""


def test_build_value_passthrough(engine):
    engine.spawn(
        "sl2", "SliderNode",
        params={
            "min": -10.0, "max": 10.0, "value": 2.5,
            "step": 0.5,
            "orientation": "vertical",
            "parameter_target": "box_v1.corner_radius",
            "layer": 7,
            "displayed_by": "slider_knob_v1",
        },
    )
    s = engine.nodes["sl2"].state
    assert s["min"] == -10.0
    assert s["max"] == 10.0
    assert s["value"] == 2.5
    assert s["step"] == 0.5
    assert s["orientation"] == "vertical"
    assert s["parameter_target"] == "box_v1.corner_radius"
    assert s["displayed_by"] == "slider_knob_v1"


def test_build_invalid_orientation_falls_back(engine):
    engine.spawn("sl_o", "SliderNode", params={"orientation": "diagonal"})
    assert engine.nodes["sl_o"].state["orientation"] == "horizontal"


def test_build_zero_step_clamps_to_default(engine):
    """Negative or zero step would break step_up/down — clamp to default."""
    engine.spawn("sl_s0", "SliderNode", params={"step": 0.0})
    assert engine.nodes["sl_s0"].state["step"] == 0.01

    engine.spawn("sl_sneg", "SliderNode", params={"step": -1.0})
    assert engine.nodes["sl_sneg"].state["step"] == 0.01


def test_emit_returns_channels(engine, view):
    engine.spawn("sl3", "SliderNode", params={"value": 0.5})
    n = engine.nodes["sl3"]
    ch = engine.types["SliderNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert ch["color"].shape == (view.height, view.width, 3)


def test_emit_different_value_different_output(engine, view):
    engine.spawn("sl_lo", "SliderNode", params={"value": 0.0})
    engine.spawn("sl_hi", "SliderNode", params={"value": 1.0})
    lo = engine.types["SliderNode"].emit(
        engine.nodes["sl_lo"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sl_lo"]),
    )
    hi = engine.types["SliderNode"].emit(
        engine.nodes["sl_hi"].state, view,
        EmitContext(engine=engine, node=engine.nodes["sl_hi"]),
    )
    assert not np.array_equal(lo["color"], hi["color"])


def test_describe_one_line(engine):
    engine.spawn("sl_d", "SliderNode",
                 params={"min": 0.0, "max": 10.0, "value": 5.0,
                         "step": 0.1,
                         "parameter_target": "box.corner_radius"})
    n = engine.nodes["sl_d"]
    text = engine.types["SliderNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "SliderNode" in text
    assert "5.000" in text
    assert "box.corner_radius" in text


# ---------- handle_action ----------


def _dispatch(engine, node_id, verb, payload=None):
    n = engine.nodes[node_id]
    return engine.types["SliderNode"].handle_action(
        n.state, verb, payload or {}, engine, n,
    )


def test_set_value_persists_and_snaps_to_step(engine):
    engine.spawn("sl_sv", "SliderNode",
                 params={"min": 0.0, "max": 1.0, "step": 0.25})
    # 0.7 snaps to nearest multiple of 0.25 from 0 → 0.75.
    d = _dispatch(engine, "sl_sv", "set_value", {"value": 0.7})
    assert d["last_set_value"]["set"] is True
    assert d["last_set_value"]["value"] == 0.75
    assert engine.nodes["sl_sv"].state["value"] == 0.75


def test_set_value_clamps_to_max(engine):
    engine.spawn("sl_cl", "SliderNode",
                 params={"min": 0.0, "max": 1.0, "step": 0.1})
    d = _dispatch(engine, "sl_cl", "set_value", {"value": 2.0})
    assert d["last_set_value"]["set"] is True
    assert d["last_set_value"]["value"] == 1.0


def test_set_value_invalid_payload(engine):
    engine.spawn("sl_bad", "SliderNode", params={})
    d = _dispatch(engine, "sl_bad", "set_value", {"value": "abc"})
    assert d["last_set_value"]["set"] is False


def test_get_value_reads_back(engine):
    engine.spawn("sl_gv", "SliderNode", params={"value": 0.42, "step": 0.01})
    d = _dispatch(engine, "sl_gv", "get_value")
    assert abs(d["value"] - 0.42) < 1e-6


def test_step_up_increments_by_step(engine):
    engine.spawn("sl_su", "SliderNode",
                 params={"min": 0.0, "max": 1.0, "step": 0.1, "value": 0.5})
    d = _dispatch(engine, "sl_su", "step_up")
    assert d["last_step_up"]["from"] == 0.5
    assert abs(d["value"] - 0.6) < 1e-6
    assert abs(engine.nodes["sl_su"].state["value"] - 0.6) < 1e-6


def test_step_down_decrements_by_step(engine):
    engine.spawn("sl_sd", "SliderNode",
                 params={"min": 0.0, "max": 1.0, "step": 0.1, "value": 0.5})
    d = _dispatch(engine, "sl_sd", "step_down")
    assert abs(d["value"] - 0.4) < 1e-6


def test_step_up_clamps_at_max(engine):
    engine.spawn("sl_smax", "SliderNode",
                 params={"min": 0.0, "max": 1.0, "step": 0.5, "value": 0.8})
    d = _dispatch(engine, "sl_smax", "step_up")
    assert d["value"] == 1.0


def test_unknown_action_returns_none(engine):
    engine.spawn("sl_u", "SliderNode", params={})
    n = engine.nodes["sl_u"]
    out = engine.types["SliderNode"].handle_action(
        n.state, "nonexistent", {}, engine, n,
    )
    assert out is None
