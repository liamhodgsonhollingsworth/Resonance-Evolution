"""
Tests for ButtonNode — SPEC-077.

ButtonNode is the first-class scene-graph node-type for clickable
buttons attached to other nodes. These tests cover:

- Registration through ``engine.discover()``.
- ``build()`` default-fill — every design field is present with the
  documented default.
- ``build()`` value-passthrough — supplied values survive build.
- Invalid ``payload`` types fall back to an empty dict (defensive).
- ``describe()`` produces a one-line summary including parent + action.
- ``emit()`` returns empty render channels (no visual contribution).
- ``select_children()`` returns ``[]`` (no recursion).
- Icon resolution soft-fails when SPEC-069's ``visual_contract`` is
  absent (which is the case in this PR).
- Round-trip through the standard module-clipboard serializer.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.node import EmitContext  # noqa: E402


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def test_button_node_registers(engine):
    assert "ButtonNode" in engine.types
    m = engine.types["ButtonNode"].manifest()
    assert m.name == "ButtonNode"
    assert m.version == "1.0"


def test_build_defaults_full_state(engine):
    engine.spawn("b1", "ButtonNode", params={})
    node = engine.nodes["b1"]
    assert not node.dead
    state = node.state
    # Every design-doc field must be present with the documented default.
    assert state["label"] == ""
    assert state["icon"] == ""
    assert state["action"] == ""
    assert state["target"] == ""
    assert state["payload"] == {}
    assert state["position"] == "row"
    assert state["order"] == 0
    assert state["parent"] == ""
    assert state["standard"] is False
    assert state["hidden"] is False


def test_build_value_passthrough(engine):
    engine.spawn(
        "b2",
        "ButtonNode",
        params={
            "label": "Pin",
            "icon": "pin",
            "action": "pin-panel",
            "target": "panel:task_panel",
            "payload": {"k": "v"},
            "position": "row",
            "order": 7,
            "parent": "task_panel",
            "standard": True,
        },
    )
    state = engine.nodes["b2"].state
    assert state["label"] == "Pin"
    assert state["icon"] == "pin"
    assert state["action"] == "pin-panel"
    assert state["target"] == "panel:task_panel"
    assert state["payload"] == {"k": "v"}
    assert state["order"] == 7
    assert state["parent"] == "task_panel"
    assert state["standard"] is True


def test_build_invalid_payload_falls_back_to_empty(engine):
    """A non-dict payload must not crash build() — defensive default."""
    engine.spawn(
        "b3", "ButtonNode", params={"payload": "not-a-dict"},
    )
    node = engine.nodes["b3"]
    assert not node.dead
    assert node.state["payload"] == {}


def test_describe_one_line(engine):
    engine.spawn(
        "b4",
        "ButtonNode",
        params={
            "label": "History",
            "action": "show-history",
            "target": "node:focus",
            "parent": "focus",
        },
    )
    node = engine.nodes["b4"]
    ctx = EmitContext(engine=engine, node=node)
    text = engine.types["ButtonNode"].describe(node.state, ctx)
    assert "History" in text
    assert "show-history" in text
    assert "focus" in text


def test_describe_marks_standard_and_hidden(engine):
    engine.spawn(
        "b5",
        "ButtonNode",
        params={
            "label": "Custom",
            "action": "do-it",
            "standard": True,
            "hidden": True,
        },
    )
    node = engine.nodes["b5"]
    ctx = EmitContext(engine=engine, node=node)
    text = engine.types["ButtonNode"].describe(node.state, ctx)
    assert "standard" in text
    assert "hidden" in text


def test_emit_returns_empty_channels(engine):
    engine.spawn(
        "b6",
        "ButtonNode",
        params={"label": "Test", "action": "noop"},
    )
    node = engine.nodes["b6"]
    view = View(width=16, height=12)
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["ButtonNode"].emit(node.state, view, ctx)
    assert "color" in channels
    assert "depth" in channels
    # Color is all zero (no visual contribution).
    assert channels["color"].shape == (12, 16, 3)
    assert channels["color"].sum() == 0
    # Depth is all +infinity (nothing in front of anything).
    import numpy as np
    assert np.all(np.isposinf(channels["depth"]))


def test_select_children_returns_empty(engine):
    engine.spawn("b7", "ButtonNode", params={})
    node = engine.nodes["b7"]
    children = engine.types["ButtonNode"].select_children(
        node.state, View(), engine, node,
    )
    assert children == []


def test_resolve_icon_known_set_passes_through():
    from node_types.button import KNOWN_ICONS, resolve_icon
    for name in KNOWN_ICONS:
        assert resolve_icon(name) == name


def test_resolve_icon_empty_returns_none():
    from node_types.button import resolve_icon
    assert resolve_icon("") is None


def test_resolve_icon_unknown_returns_raw_name():
    """When visual_contract is absent (this PR's runtime), an unknown
    icon falls through to the raw name. The GUI shell renders
    label-only when the renderer can't find a glyph."""
    from node_types.button import resolve_icon
    assert resolve_icon("nonexistent-icon") == "nonexistent-icon"


def test_round_trip_via_module_clipboard(engine):
    """A ButtonNode must serialize + paste through the existing
    SPEC-073 clipboard with no special-case handling."""
    from tools.module_clipboard import paste_text_to_engine, serialize_module

    engine.spawn(
        "src_btn",
        "ButtonNode",
        params={
            "label": "Pin",
            "icon": "pin",
            "action": "pin-panel",
            "target": "panel:task_panel",
            "parent": "task_panel",
            "order": 5,
        },
    )
    text = serialize_module(engine, "src_btn", include_subtree=True)
    new_ids = paste_text_to_engine(engine, text)
    assert "src_btn_2" in new_ids
    copied = engine.nodes["src_btn_2"]
    assert copied.type_name == "ButtonNode"
    assert copied.state["label"] == "Pin"
    assert copied.state["action"] == "pin-panel"
    assert copied.state["parent"] == "task_panel"


def test_dead_button_isolates_from_engine(engine):
    """A ButtonNode whose params produce a build failure must mark
    itself dead without leaking the exception to the engine's discover
    or precompute paths.

    Since ButtonNode's build() is total over the documented input
    types, we have to coerce a failure via a deliberately-bad param
    set. Passing an unstringifiable ``label`` triggers ``str(...)``
    failure inside build.
    """

    class _Unstringable:
        def __str__(self):
            raise RuntimeError("intentional")

    engine.spawn("b_dead", "ButtonNode", params={"label": _Unstringable()})
    node = engine.nodes["b_dead"]
    assert node.dead is True
    assert "build failed" in node.error


def test_two_buttons_with_same_parent_coexist(engine):
    """The button-row builder relies on multiple ButtonNodes sharing
    a parent. Spawning two with the same parent must both stick."""
    engine.spawn("ba", "ButtonNode", params={"parent": "task_panel", "order": 1})
    engine.spawn("bb", "ButtonNode", params={"parent": "task_panel", "order": 2})
    assert engine.nodes["ba"].state["parent"] == "task_panel"
    assert engine.nodes["bb"].state["parent"] == "task_panel"
    assert engine.nodes["ba"].state["order"] == 1
    assert engine.nodes["bb"].state["order"] == 2
