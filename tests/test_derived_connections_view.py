"""
Tests for the derived button-row + connections view — SPEC-076.

The Author / History / Connections row is computed on demand (not
spawned as three real ButtonNodes per node — that's the 4x explosion
the design rejects). These tests verify:

- ``button_row_for`` returns the three standards by default.
- Customizations (real ButtonNodes whose parent matches) compose with
  the standards in display order.
- Standard overrides (``standard=True, action=<standard-action>``)
  REPLACE the matching implicit standard.
- A ``hidden=True`` standard override SUPPRESSES the corresponding
  implicit entry (the suppress-standard idiom in §10).
- Customizations sort by ``order`` with ties broken by id.
- ``connections_for`` returns the correct in-edges + out-edges in a
  small synthetic scene.
- ``dispatch_standard`` returns the correct response shape for each of
  show-author / show-history / show-connections.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from tools.button_view import (  # noqa: E402
    button_row_for,
    buttons_attached_to,
    connections_for,
    dispatch_standard,
)


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


# ---------------------------------------------------------------------------
# button_row_for: implicit standards + customizations
# ---------------------------------------------------------------------------


def test_default_row_has_three_standards(engine):
    """Every node-instance gets Author / History / Connections by
    default — the standards are derived, not spawned."""
    engine.spawn("focus", "ButtonNode", params={})
    row = button_row_for(engine, "focus")
    assert len(row) == 3
    assert [b.label for b in row] == ["Author", "History", "Connections"]
    for spec in row:
        assert spec.standard is True
        # Standards have no real ButtonNode backing them.
        assert spec.button_id == ""


def test_standards_target_focused_node(engine):
    engine.spawn("focus", "ButtonNode", params={})
    row = button_row_for(engine, "focus")
    for spec in row:
        assert spec.target == "node:focus"
        assert spec.parent == "focus"


def test_customization_appends_after_standards(engine):
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "pin_btn", "ButtonNode",
        params={
            "label": "Pin",
            "action": "pin-panel",
            "target": "node:focus",
            "parent": "focus",
            "order": 5,
        },
    )
    row = button_row_for(engine, "focus")
    assert len(row) == 4
    assert [b.label for b in row] == ["Author", "History", "Connections", "Pin"]
    pin = row[3]
    assert pin.button_id == "pin_btn"
    assert pin.standard is False
    assert pin.order == 5


def test_two_customizations_sort_by_order(engine):
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "b_late", "ButtonNode",
        params={
            "label": "Late",
            "action": "x",
            "parent": "focus",
            "order": 99,
        },
    )
    engine.spawn(
        "a_early", "ButtonNode",
        params={
            "label": "Early",
            "action": "y",
            "parent": "focus",
            "order": 1,
        },
    )
    row = button_row_for(engine, "focus")
    labels = [b.label for b in row]
    assert labels[3] == "Early"   # order=1
    assert labels[4] == "Late"    # order=99


def test_standard_override_replaces_implicit(engine):
    """A real ButtonNode with ``standard=True`` and a matching action
    REPLACES the implicit standard. Maintainer customization of the
    History icon, for instance."""
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "custom_history", "ButtonNode",
        params={
            "label": "Versions",
            "action": "show-history",
            "icon": "clock-rewind",
            "target": "node:focus",
            "parent": "focus",
            "standard": True,
        },
    )
    row = button_row_for(engine, "focus")
    labels = [b.label for b in row]
    assert labels == ["Author", "Versions", "Connections"]
    # The History slot now points at the real ButtonNode.
    history_spec = row[1]
    assert history_spec.button_id == "custom_history"


def test_standard_override_with_hidden_suppresses_entry(engine):
    """A ``standard=True, hidden=True`` ButtonNode SUPPRESSES the
    matching implicit standard — design's §10 'remove Connections
    from this type' idiom."""
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "hide_connections", "ButtonNode",
        params={
            "label": "x",
            "action": "show-connections",
            "parent": "focus",
            "standard": True,
            "hidden": True,
        },
    )
    row = button_row_for(engine, "focus")
    labels = [b.label for b in row]
    assert "Connections" not in labels
    assert labels == ["Author", "History"]


def test_hidden_customization_is_filtered(engine):
    """A regular (non-standard) ``hidden=True`` button just disappears."""
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "hidden_pin", "ButtonNode",
        params={
            "label": "Hidden",
            "action": "x",
            "parent": "focus",
            "hidden": True,
        },
    )
    row = button_row_for(engine, "focus")
    assert "Hidden" not in [b.label for b in row]
    assert len(row) == 3


def test_dead_buttons_excluded_from_row(engine):
    """A dead ButtonNode is filtered out — composes with the engine's
    archive/restore primitives."""
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "dead_btn", "ButtonNode",
        params={"label": "Dead", "action": "x", "parent": "focus"},
    )
    engine.archive("dead_btn")
    row = button_row_for(engine, "focus")
    assert "Dead" not in [b.label for b in row]


def test_buttons_attached_to_lists_real_nodes_only(engine):
    """The standard buttons should NEVER appear in
    ``buttons_attached_to`` — they're derived, not real."""
    engine.spawn("focus", "ButtonNode", params={})
    engine.spawn(
        "real_btn", "ButtonNode",
        params={"label": "R", "action": "x", "parent": "focus"},
    )
    attached = buttons_attached_to(engine, "focus")
    assert attached == ["real_btn"]


def test_no_4x_explosion_in_engine_nodes(engine):
    """Confirm the design's load-bearing claim: spawning N nodes does
    NOT create 4x ButtonNodes (3 standards per parent + parent)."""
    parents_before = len(engine.nodes)
    for i in range(10):
        engine.spawn(f"parent_{i}", "ButtonNode", params={})
    parents_after = len(engine.nodes)
    growth = parents_after - parents_before
    # Exactly 10 new nodes, not 40.
    assert growth == 10


# ---------------------------------------------------------------------------
# connections_for: in/out edges
# ---------------------------------------------------------------------------


def test_connections_for_empty_node(engine):
    engine.spawn("solo", "ButtonNode", params={})
    edges = connections_for(engine, "solo")
    assert edges == {"out": [], "in": []}


def test_connections_for_missing_node_returns_empty(engine):
    edges = connections_for(engine, "ghost")
    assert edges == {"out": [], "in": []}


def test_connections_for_out_edges(engine):
    engine.spawn("a", "ButtonNode", params={})
    engine.spawn("b", "ButtonNode", params={})
    engine.spawn("c", "ButtonNode", params={})
    engine.connect("a", "next", "b")
    engine.connect("a", "alt", "c")
    edges = connections_for(engine, "a")
    out_targets = {e["target_id"] for e in edges["out"]}
    assert out_targets == {"b", "c"}


def test_connections_for_in_edges(engine):
    engine.spawn("a", "ButtonNode", params={})
    engine.spawn("b", "ButtonNode", params={})
    engine.spawn("c", "ButtonNode", params={})
    engine.connect("b", "next", "a")
    engine.connect("c", "alt", "a")
    edges = connections_for(engine, "a")
    in_sources = {e["from_id"] for e in edges["in"]}
    assert in_sources == {"b", "c"}


def test_connections_for_handles_polymorphic_conn_shape(engine):
    """The connection layer supports str, dict, and list shapes —
    the connections-view must decode all three."""
    engine.spawn("a", "ButtonNode", params={})
    engine.spawn("b", "ButtonNode", params={})
    engine.spawn("c", "ButtonNode", params={})
    engine.spawn("d", "ButtonNode", params={})
    # string shape
    engine.connect("a", "s1", "b")
    # dict shape
    engine.nodes["a"].connections["s2"] = {"target": "c"}
    # list shape
    engine.nodes["a"].connections["s3"] = ["d", None]
    edges = connections_for(engine, "a")
    out_targets = {e["target_id"] for e in edges["out"]}
    assert {"b", "c", "d"}.issubset(out_targets)


def test_connections_for_excludes_self_loop_from_in_edges(engine):
    """A node's own out-edges should not appear in its in-edges list
    (the walk excludes the focused node from its own in-search)."""
    engine.spawn("a", "ButtonNode", params={})
    engine.connect("a", "self", "a")
    edges = connections_for(engine, "a")
    # Self-loop appears as an out-edge.
    assert any(e["target_id"] == "a" for e in edges["out"])
    # But NOT as a separate in-edge entry (we skip other_id == node_id).
    assert all(e["from_id"] != "a" for e in edges["in"])


# ---------------------------------------------------------------------------
# dispatch_standard: derived-view responses
# ---------------------------------------------------------------------------


def test_dispatch_standard_show_author_with_explicit_field(engine):
    engine.spawn("a", "ButtonNode", params={"author": "Liam"})
    out = dispatch_standard(engine, "a", "show-author")
    assert out["type"] == "author"
    assert "Liam" in out["summary"]


def test_dispatch_standard_show_author_derived(engine):
    engine.spawn("b", "ButtonNode", params={})
    out = dispatch_standard(engine, "b", "show-author")
    assert out["type"] == "author"
    assert "derived" in out["summary"]
    assert "ButtonNode" in out["summary"]


def test_dispatch_standard_show_history_returns_rows(tmp_path):
    """show-history returns whatever the history file contains."""
    e = Engine(root_dir=tmp_path)
    e.discover()
    e.spawn("c", "ButtonNode", params={})
    out = dispatch_standard(e, "c", "show-history")
    assert out["type"] == "history"
    # Spawn wrote a row.
    assert len(out["rows"]) >= 1


def test_dispatch_standard_show_connections(engine):
    engine.spawn("a", "ButtonNode", params={})
    engine.spawn("b", "ButtonNode", params={})
    engine.connect("a", "next", "b")
    out = dispatch_standard(engine, "a", "show-connections")
    assert out["type"] == "connections"
    assert any(e["target_id"] == "b" for e in out["edges"]["out"])


def test_dispatch_standard_unknown_action(engine):
    engine.spawn("a", "ButtonNode", params={})
    out = dispatch_standard(engine, "a", "totally-unknown")
    assert out["type"] == "unknown"
    assert out["action"] == "totally-unknown"


def test_dispatch_standard_show_author_missing_node(engine):
    out = dispatch_standard(engine, "ghost", "show-author")
    assert out["type"] == "author"
    assert "no node" in out["summary"]
