"""Tests for TextBoxNode — N-F020 / SPEC-094 foundational primitive.

Brief 03 commit 2 of the Resonance website implementation arc — the
second of the three foundational primitives. Covers:

- Engine discovery.
- Default-build state.
- Value-passthrough.
- Display-mode enum (plain/markdown/code, default plain; invalid →
  plain).
- emit() returns channels of view dimensions.
- emit() responds to ``text`` content — different text → different
  output.
- emit() is deterministic.
- Scrollable + scroll_value path — different scroll_value produces
  different output when scrollable is True and text exceeds the visible
  area.
- describe() truncates long text and surfaces display_mode + scroll
  state.
- accepts_drop() returns True for the documented kinds (slot
  validation pre-commit-5).
- Composition against engine/screen.py — confirmed by visible text
  rendering (not byte-equivalent — that's the engine_screen test's job
  — but the helpers must be the ones the primitive uses).
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
        width=64, height=64,
    )


# ---------- registration ----------


def test_text_box_node_registers(engine):
    assert "TextBoxNode" in engine.types
    m = engine.types["TextBoxNode"].manifest()
    assert m.name == "TextBoxNode"
    assert m.version == "1.0"


# ---------- build ----------


def test_build_defaults_full_state(engine):
    engine.spawn("tb1", "TextBoxNode", params={})
    s = engine.nodes["tb1"].state
    assert s["text"] == ""
    assert s["display_mode"] == "plain"
    assert s["scrollable"] is False
    assert s["scroll_value"] == 0.0
    assert s["parent_box"] == ""
    assert s["layer"] == 0
    assert s["displayed_by"] == ""
    assert s["font_size"] == 14


def test_build_value_passthrough(engine):
    engine.spawn(
        "tb2", "TextBoxNode",
        params={
            "text": "Hello, world!",
            "display_mode": "markdown",
            "scrollable": True,
            "scroll_value": 0.42,
            "parent_box": "box_outer",
            "font_size": 18,
            "corner_radius": 0.1,
            "layer": 5,
        },
    )
    s = engine.nodes["tb2"].state
    assert s["text"] == "Hello, world!"
    assert s["display_mode"] == "markdown"
    assert s["scrollable"] is True
    assert s["scroll_value"] == 0.42
    assert s["parent_box"] == "box_outer"
    assert s["font_size"] == 18
    assert s["corner_radius"] == 0.1
    assert s["layer"] == 5


def test_build_invalid_display_mode_falls_back_to_plain(engine):
    engine.spawn("tb3", "TextBoxNode", params={"display_mode": "nonsense"})
    assert engine.nodes["tb3"].state["display_mode"] == "plain"


def test_build_all_three_display_modes_accepted(engine):
    from node_types.text_box import DISPLAY_MODES
    for i, mode in enumerate(DISPLAY_MODES):
        engine.spawn(f"tb_mode_{i}", "TextBoxNode", params={"display_mode": mode})
        assert engine.nodes[f"tb_mode_{i}"].state["display_mode"] == mode


# ---------- emit ----------


def test_emit_returns_channels(engine, view):
    engine.spawn("tb4", "TextBoxNode", params={"text": "hi"})
    n = engine.nodes["tb4"]
    ch = engine.types["TextBoxNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert "color" in ch and "depth" in ch
    assert ch["color"].shape == (view.height, view.width, 3)
    assert ch["color"].dtype == np.float32


def test_emit_produces_non_zero_color(engine, view):
    """Text on a background renders pixels."""
    engine.spawn(
        "tb5", "TextBoxNode",
        params={
            "text": "ABC",
            "screen_width": 4.0,
            "screen_height": 3.0,
            "background_color": [0.5, 0.5, 0.5],
        },
    )
    n = engine.nodes["tb5"]
    ch = engine.types["TextBoxNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert ch["color"].sum() > 0


def test_emit_deterministic(engine, view):
    engine.spawn("tb6", "TextBoxNode", params={"text": "deterministic"})
    n = engine.nodes["tb6"]
    ctx = EmitContext(engine=engine, node=n)
    out1 = engine.types["TextBoxNode"].emit(n.state, view, ctx)
    out2 = engine.types["TextBoxNode"].emit(n.state, view, ctx)
    np.testing.assert_array_equal(out1["color"], out2["color"])


def test_emit_different_text_different_output(engine, view):
    """Different ``text`` content yields different rendered output."""
    engine.spawn("tb_a", "TextBoxNode", params={
        "text": "First content", "screen_width": 4.0, "screen_height": 3.0,
    })
    engine.spawn("tb_b", "TextBoxNode", params={
        "text": "Different content", "screen_width": 4.0, "screen_height": 3.0,
    })
    a = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_a"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_a"]),
    )
    b = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_b"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_b"]),
    )
    # The two rasters should differ (texts differ).
    assert not np.array_equal(a["color"], b["color"])


def test_scrollable_responds_to_scroll_value(engine, view):
    """When scrollable AND text exceeds visible area, different
    scroll_values produce different visible content."""
    long_text = "\n".join(f"line {i}" for i in range(50))
    engine.spawn("tb_top", "TextBoxNode", params={
        "text": long_text, "scrollable": True, "scroll_value": 0.0,
        "screen_width": 3.0, "screen_height": 1.5,
    })
    engine.spawn("tb_bot", "TextBoxNode", params={
        "text": long_text, "scrollable": True, "scroll_value": 1.0,
        "screen_width": 3.0, "screen_height": 1.5,
    })
    top = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_top"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_top"]),
    )
    bot = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_bot"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_bot"]),
    )
    # Top of long text vs bottom of long text → different rasters.
    assert not np.array_equal(top["color"], bot["color"])


def test_non_scrollable_ignores_scroll_value(engine, view):
    """When scrollable is False, scroll_value has no effect."""
    long_text = "\n".join(f"line {i}" for i in range(50))
    engine.spawn("tb_ns_0", "TextBoxNode", params={
        "text": long_text, "scrollable": False, "scroll_value": 0.0,
    })
    engine.spawn("tb_ns_1", "TextBoxNode", params={
        "text": long_text, "scrollable": False, "scroll_value": 0.9,
    })
    a = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_ns_0"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_ns_0"]),
    )
    b = engine.types["TextBoxNode"].emit(
        engine.nodes["tb_ns_1"].state, view,
        EmitContext(engine=engine, node=engine.nodes["tb_ns_1"]),
    )
    np.testing.assert_array_equal(a["color"], b["color"])


# ---------- describe ----------


def test_describe_truncates_long_text(engine):
    long = "x" * 100
    engine.spawn("tb_desc", "TextBoxNode", params={"text": long})
    n = engine.nodes["tb_desc"]
    text = engine.types["TextBoxNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "…" in text  # Ellipsis indicates truncation.
    assert "TextBoxNode" in text
    assert "tb_desc" in text


def test_describe_surfaces_display_mode_and_scroll(engine):
    engine.spawn("tb_md", "TextBoxNode", params={
        "text": "short", "display_mode": "markdown",
        "scrollable": True, "scroll_value": 0.7,
    })
    n = engine.nodes["tb_md"]
    text = engine.types["TextBoxNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "markdown" in text
    assert "scrollable=True" in text
    assert "0.70" in text


# ---------- accepts_drop ----------


def test_accepts_drop_for_documented_kinds():
    from node_types.text_box import accepts_drop
    assert accepts_drop("MarkdownDisplayNode") is True
    assert accepts_drop("TextDisplayNode") is True
    assert accepts_drop("CodeDisplayNode") is True
    assert accepts_drop("ScrollBarNode") is True
    assert accepts_drop("DropdownNode") is True


def test_accepts_drop_rejects_unknown_kind():
    from node_types.text_box import accepts_drop
    assert accepts_drop("RandomNeverSeenKind") is False
    assert accepts_drop("") is False


# ---------- shared helper composition ----------


def test_text_box_uses_shared_engine_screen_helpers():
    """Sanity: text_box.py imports + uses the brief 03 commit 1
    extraction. Forces a regression if a follow-up commit accidentally
    forks the helper.
    """
    from node_types import text_box
    from engine import screen
    # The text_box module re-imports the helpers; verify they're the
    # SAME function objects as engine.screen exports.
    assert text_box._get_font is screen._get_font
    assert text_box._wrap_line is screen._wrap_line
    assert text_box._paste_onto_screen_rectangle is screen._paste_onto_screen_rectangle
