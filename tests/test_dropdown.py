"""Tests for DropdownNode — N-F027 / SPEC-090 functional primitive.

Brief 03 commit 3. Covers registration, build (options normalization +
selected-fallback), select/add_option/remove_option/get_selected_label
verbs, emit differing on selection change, describe content,
displayed_by slot.
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
        width=128, height=32,
    )


def test_dropdown_node_registers(engine):
    assert "DropdownNode" in engine.types
    m = engine.types["DropdownNode"].manifest()
    assert m.name == "DropdownNode"
    expected = {
        "options", "selected", "on_change_action",
        "layer", "displayed_by",
    }
    assert expected.issubset(set(m.inputs.keys()))


def test_build_defaults(engine):
    engine.spawn("dd1", "DropdownNode", params={})
    s = engine.nodes["dd1"].state
    assert s["options"] == []
    assert s["selected"] == ""
    assert s["on_change_action"] == ""


def test_build_value_passthrough(engine):
    engine.spawn(
        "dd2", "DropdownNode",
        params={
            "options": [
                {"id": "md", "label": "Markdown"},
                {"id": "txt", "label": "Plain Text"},
                {"id": "code", "label": "Code"},
            ],
            "selected": "txt",
            "on_change_action": "set_display_mode",
            "on_change_target": "text_box_main",
            "displayed_by": "dropdown_chunky_v1",
        },
    )
    s = engine.nodes["dd2"].state
    assert len(s["options"]) == 3
    assert s["options"][0] == {"id": "md", "label": "Markdown"}
    assert s["selected"] == "txt"
    assert s["on_change_action"] == "set_display_mode"
    assert s["on_change_target"] == "text_box_main"
    assert s["displayed_by"] == "dropdown_chunky_v1"


def test_build_skips_malformed_options(engine):
    engine.spawn("dd3", "DropdownNode", params={
        "options": [
            "not a dict",
            {"id": "", "label": "empty id"},   # skipped: empty id
            {"id": "ok", "label": "Good"},
            42,
            {"id": "dup", "label": "First"},
            {"id": "dup", "label": "Duplicate"},  # skipped: dup id
        ],
    })
    s = engine.nodes["dd3"].state
    assert len(s["options"]) == 2
    assert {o["id"] for o in s["options"]} == {"ok", "dup"}


def test_build_selected_falls_back_to_first_option(engine):
    """An invalid `selected` (not in options) falls back to first option."""
    engine.spawn("dd4", "DropdownNode", params={
        "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
        "selected": "nonexistent",
    })
    assert engine.nodes["dd4"].state["selected"] == "a"


def test_build_selected_empty_with_options_gets_first(engine):
    engine.spawn("dd5", "DropdownNode", params={
        "options": [{"id": "x", "label": "X"}],
    })
    assert engine.nodes["dd5"].state["selected"] == "x"


# ---------- emit ----------


def test_emit_returns_channels(engine, view):
    engine.spawn("dd_em", "DropdownNode", params={
        "options": [{"id": "a", "label": "Alpha"}],
    })
    n = engine.nodes["dd_em"]
    ch = engine.types["DropdownNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert ch["color"].shape == (view.height, view.width, 3)


def test_emit_different_selection_different_output(engine, view):
    """Different selected labels render different text → different output."""
    engine.spawn("dd_a", "DropdownNode", params={
        "options": [{"id": "a", "label": "Alpha"},
                    {"id": "b", "label": "Beta"}],
        "selected": "a",
    })
    engine.spawn("dd_b", "DropdownNode", params={
        "options": [{"id": "a", "label": "Alpha"},
                    {"id": "b", "label": "Beta"}],
        "selected": "b",
    })
    a = engine.types["DropdownNode"].emit(
        engine.nodes["dd_a"].state, view,
        EmitContext(engine=engine, node=engine.nodes["dd_a"]),
    )
    b = engine.types["DropdownNode"].emit(
        engine.nodes["dd_b"].state, view,
        EmitContext(engine=engine, node=engine.nodes["dd_b"]),
    )
    assert not np.array_equal(a["color"], b["color"])


def test_describe_one_line(engine):
    engine.spawn("dd_d", "DropdownNode", params={
        "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
        "selected": "b",
        "on_change_action": "set_mode",
    })
    n = engine.nodes["dd_d"]
    text = engine.types["DropdownNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "DropdownNode" in text
    assert "options=2" in text
    assert "'b'" in text
    assert "set_mode" in text


# ---------- handle_action ----------


def _dispatch(engine, node_id, verb, payload=None):
    n = engine.nodes[node_id]
    return engine.types["DropdownNode"].handle_action(
        n.state, verb, payload or {}, engine, n,
    )


def test_select_persists_and_surfaces_on_change(engine):
    engine.spawn("dd_sel", "DropdownNode", params={
        "options": [{"id": "md", "label": "MD"}, {"id": "txt", "label": "TXT"}],
        "selected": "md",
        "on_change_action": "set_display_mode",
        "on_change_target": "text_box_main",
    })
    d = _dispatch(engine, "dd_sel", "select", {"option_id": "txt"})
    assert d["last_select"]["selected"] is True
    assert d["last_select"]["option_id"] == "txt"
    assert d["last_select"]["previous"] == "md"
    assert d["last_select"]["on_change_action"] == "set_display_mode"
    assert d["last_select"]["on_change_target"] == "text_box_main"
    assert engine.nodes["dd_sel"].state["selected"] == "txt"


def test_select_unknown_option_rejected(engine):
    engine.spawn("dd_unk", "DropdownNode", params={
        "options": [{"id": "x", "label": "X"}],
    })
    d = _dispatch(engine, "dd_unk", "select", {"option_id": "nope"})
    assert d["last_select"]["selected"] is False


def test_select_empty_option_id_rejected(engine):
    engine.spawn("dd_emp", "DropdownNode", params={
        "options": [{"id": "x", "label": "X"}],
    })
    d = _dispatch(engine, "dd_emp", "select", {"option_id": ""})
    assert d["last_select"]["selected"] is False


def test_add_option_appends(engine):
    engine.spawn("dd_add", "DropdownNode", params={"options": []})
    d = _dispatch(engine, "dd_add", "add_option",
                  {"id": "new1", "label": "New One"})
    assert d["last_add_option"]["added"] is True
    assert d["last_add_option"]["index"] == 0
    assert engine.nodes["dd_add"].state["options"] == [
        {"id": "new1", "label": "New One"},
    ]
    # First-add into an empty dropdown sets selected automatically.
    assert engine.nodes["dd_add"].state["selected"] == "new1"


def test_add_option_duplicate_rejected(engine):
    engine.spawn("dd_dup", "DropdownNode", params={
        "options": [{"id": "x", "label": "X"}],
    })
    d = _dispatch(engine, "dd_dup", "add_option", {"id": "x", "label": "X-2"})
    assert d["last_add_option"]["added"] is False


def test_remove_option_drops_by_id(engine):
    engine.spawn("dd_rm", "DropdownNode", params={
        "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
        "selected": "a",
    })
    d = _dispatch(engine, "dd_rm", "remove_option", {"id": "a"})
    assert d["last_remove_option"]["removed"] is True
    s = engine.nodes["dd_rm"].state
    assert s["options"] == [{"id": "b", "label": "B"}]
    # Removing the selected option falls back to first remaining.
    assert s["selected"] == "b"


def test_remove_option_unknown_returns_false(engine):
    engine.spawn("dd_rmu", "DropdownNode", params={
        "options": [{"id": "x", "label": "X"}],
    })
    d = _dispatch(engine, "dd_rmu", "remove_option", {"id": "nope"})
    assert d["last_remove_option"]["removed"] is False


def test_get_selected_label_reads(engine):
    engine.spawn("dd_gl", "DropdownNode", params={
        "options": [{"id": "x", "label": "Xenon"}],
        "selected": "x",
    })
    d = _dispatch(engine, "dd_gl", "get_selected_label")
    assert d["last_get_selected_label"]["label"] == "Xenon"


def test_unknown_action_returns_none(engine):
    engine.spawn("dd_u", "DropdownNode", params={})
    n = engine.nodes["dd_u"]
    out = engine.types["DropdownNode"].handle_action(
        n.state, "nonexistent", {}, engine, n,
    )
    assert out is None
