"""Tests for BarNode + variants (TopBarNode / BottomBarNode /
LeftSidebarNode / RightSidebarNode) — brief 04 commit 2, SPEC-112.

Covers:

- Engine discovery — each of the five kinds registers.
- Manifest shape — inherits BoxNode inputs + adds `orientation` and
  `anchor_default`.
- Per-variant defaults — anchor_default + orientation + default
  geometry (horizontal for top/bottom, vertical for left/right).
- Build value-passthrough — explicit params override variant defaults.
- emit() produces {color, depth} channels of view dimensions (the
  BoxNode default emit composes correctly through bar.py).
- emit() determinism — same input → same output.
- describe() surfaces kind + orientation + anchor.
- select_children returns empty.
- Lock delegation via the re-exported is_locked helper.
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


VARIANTS = (
    "BarNode",
    "TopBarNode",
    "BottomBarNode",
    "LeftSidebarNode",
    "RightSidebarNode",
)


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
        width=32,
        height=32,
    )


# ---------- registration ----------


@pytest.mark.parametrize("kind_name", VARIANTS)
def test_bar_variant_registers(engine, kind_name):
    """Each of the five bar kinds is discovered by Engine.discover()."""
    assert kind_name in engine.types
    m = engine.types[kind_name].manifest()
    assert m.name == kind_name
    assert m.version == "1.0"
    assert m.renderer_id == "raster"


@pytest.mark.parametrize("kind_name", VARIANTS)
def test_bar_variant_manifest_inherits_box_inputs(engine, kind_name):
    """Bar variants' inputs include every BoxNode input + the two
    bar-specific additions (orientation + anchor_default)."""
    m = engine.types[kind_name].manifest()
    box_inputs = {
        "screen_width", "screen_height", "screen_resolution",
        "corner_radius", "fill_color", "border_color", "border_width",
        "layer", "accept_unknown_drop", "displayed_by",
    }
    assert box_inputs.issubset(set(m.inputs.keys()))
    assert "orientation" in m.inputs
    assert "anchor_default" in m.inputs


# ---------- per-variant defaults ----------


def test_top_bar_default_anchor_and_orientation(engine):
    engine.spawn("top1", "TopBarNode", params={})
    s = engine.nodes["top1"].state
    assert s["anchor_default"] == "top"
    assert s["orientation"] == "horizontal"


def test_bottom_bar_default_anchor(engine):
    engine.spawn("bot1", "BottomBarNode", params={})
    s = engine.nodes["bot1"].state
    assert s["anchor_default"] == "bottom"
    assert s["orientation"] == "horizontal"


def test_left_sidebar_default_anchor_and_orientation(engine):
    engine.spawn("ls1", "LeftSidebarNode", params={})
    s = engine.nodes["ls1"].state
    assert s["anchor_default"] == "left"
    assert s["orientation"] == "vertical"


def test_right_sidebar_default_anchor(engine):
    engine.spawn("rs1", "RightSidebarNode", params={})
    s = engine.nodes["rs1"].state
    assert s["anchor_default"] == "right"
    assert s["orientation"] == "vertical"


def test_horizontal_bars_default_to_wide_short(engine):
    """Top/Bottom bars default to wider-than-tall geometry."""
    engine.spawn("top_geo", "TopBarNode", params={})
    s = engine.nodes["top_geo"].state
    assert s["screen_width"] > s["screen_height"]


def test_vertical_bars_default_to_tall_narrow(engine):
    """Left/Right sidebars default to taller-than-wide geometry."""
    engine.spawn("left_geo", "LeftSidebarNode", params={})
    s = engine.nodes["left_geo"].state
    assert s["screen_height"] > s["screen_width"]


def test_bar_default_corner_radius_is_rounded(engine):
    """All bar variants default to a non-zero corner_radius — the
    'rounded corners' the maintainer named in N-F014 verbatim."""
    engine.spawn("bar_cr", "BarNode", params={})
    s = engine.nodes["bar_cr"].state
    assert s["corner_radius"] > 0.0


# ---------- build value-passthrough ----------


def test_bar_build_overrides_anchor_default(engine):
    """Explicit anchor_default param overrides the per-variant default."""
    engine.spawn("override", "TopBarNode", params={"anchor_default": "left"})
    s = engine.nodes["override"].state
    assert s["anchor_default"] == "left"


def test_bar_build_overrides_geometry(engine):
    engine.spawn(
        "geom_over",
        "BarNode",
        params={"screen_width": 7.0, "screen_height": 1.5, "corner_radius": 0.2},
    )
    s = engine.nodes["geom_over"].state
    assert s["screen_width"] == 7.0
    assert s["screen_height"] == 1.5
    assert s["corner_radius"] == 0.2


def test_bar_inherits_box_lock_delegation():
    """The is_locked helper re-exported from bar.py is the same callable
    that BoxNode exposes — calling it on bars uses BoxNode's lock
    contract (SPEC-075)."""
    from node_types import bar, box

    assert bar.is_locked is box.is_locked
    # Smoke: with no registry, returns False.
    assert bar.is_locked("any_id", None) is False


# ---------- emit + describe ----------


@pytest.mark.parametrize("kind_name", VARIANTS)
def test_bar_emit_produces_view_sized_channels(engine, view, kind_name):
    """All variants produce {color, depth} channels matching view
    dimensions (the BoxNode raster paste composes correctly through
    bar.py)."""
    engine.spawn(f"emit_{kind_name}", kind_name, params={})
    node = engine.nodes[f"emit_{kind_name}"]
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types[kind_name].emit(node.state, view, ctx)
    assert "color" in channels
    assert "depth" in channels
    assert channels["color"].shape == (view.height, view.width, 3)


def test_bar_emit_deterministic(engine, view):
    """Same state + same view → byte-identical output (composes
    through BoxNode.emit which has the same property)."""
    engine.spawn("det1", "BarNode", params={})
    engine.spawn("det2", "BarNode", params={})
    ctx1 = EmitContext(engine=engine, node=engine.nodes["det1"])
    ctx2 = EmitContext(engine=engine, node=engine.nodes["det2"])
    out1 = engine.types["BarNode"].emit(engine.nodes["det1"].state, view, ctx1)
    out2 = engine.types["BarNode"].emit(engine.nodes["det2"].state, view, ctx2)
    np.testing.assert_array_equal(out1["color"], out2["color"])


def test_bar_describe_surfaces_kind_orientation_anchor(engine):
    """describe() one-liner mentions the kind name + the orientation +
    the anchor_default so the LLM-driver can identify the bar variant
    without re-reading the manifest."""
    engine.spawn("desc1", "RightSidebarNode", params={})
    node = engine.nodes["desc1"]
    ctx = EmitContext(engine=engine, node=node)
    out = engine.types["RightSidebarNode"].describe(node.state, ctx)
    assert "RightSidebarNode" in out
    assert "vertical" in out
    assert "'right'" in out or "right" in out


def test_bar_select_children_empty(engine, view):
    """Bars have no engine-level children (matches BoxNode + ToolboxNode
    phase-1 conventions)."""
    engine.spawn("sc1", "TopBarNode", params={})
    node = engine.nodes["sc1"]
    children = engine.types["TopBarNode"].select_children(
        node.state, view, engine, node
    )
    assert children == []
