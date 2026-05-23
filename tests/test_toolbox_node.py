"""Tests for ToolboxNode — N-F035 / SPEC-091 default container.

Brief 03 commit 2 — the third foundational primitive. Verb-set tests
mirror ``tests/test_idea_queue.py`` (the verb shape ports verbatim from
idea_queue per the per-module plan's N-F035 implementation step 1).

Covers:

- Engine discovery.
- Default-build state (empty contents, default geometry).
- Initial contents passthrough — well-formed entries survive build,
  malformed entries are skipped.
- list verb returns current contents.
- add verb (link form) — appends; no auto-flip trigger.
- add verb (rendered form, no inference rule) — appends + ambiguous-
  content auto_flip hint.
- add verb rejection — empty node_id, invalid as.
- remove verb — by node_id.
- up / down verbs — swap with neighbour; refuse at boundary.
- move verb — arbitrary swap.
- delete verb — by index.
- emit returns channels.
- describe surfaces title + counts split by as=link/as=rendered.

The auto-flip-with-inference path is exercised in
``test_toolbox_auto_flip.py`` so this file covers the verb mechanics
in isolation.
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


def test_toolbox_node_registers(engine):
    assert "ToolboxNode" in engine.types
    m = engine.types["ToolboxNode"].manifest()
    assert m.name == "ToolboxNode"


# ---------- build ----------


def test_build_defaults(engine):
    engine.spawn("tx1", "ToolboxNode", params={})
    s = engine.nodes["tx1"].state
    assert s["title"] == "Toolbox"
    assert s["contents"] == []
    assert s["layer"] == 0
    assert s["displayed_by"] == ""


def test_build_value_passthrough(engine):
    engine.spawn("tx2", "ToolboxNode", params={
        "title": "My Tools",
        "contents": [
            {"node_id": "n1", "as": "link"},
            {"node_id": "n2", "as": "rendered", "child_kind": "ButtonNode"},
        ],
        "layer": 2,
    })
    s = engine.nodes["tx2"].state
    assert s["title"] == "My Tools"
    assert s["layer"] == 2
    assert len(s["contents"]) == 2
    assert s["contents"][0] == {"node_id": "n1", "as": "link", "child_kind": ""}
    assert s["contents"][1] == {
        "node_id": "n2", "as": "rendered", "child_kind": "ButtonNode",
    }


def test_build_skips_malformed_contents(engine):
    """Non-dict entries + empty node_ids are skipped (defensive)."""
    engine.spawn("tx3", "ToolboxNode", params={
        "contents": [
            "not a dict",
            {"node_id": "", "as": "link"},  # empty id, skipped
            {"node_id": "valid", "as": "link"},
            42,
        ],
    })
    s = engine.nodes["tx3"].state
    assert len(s["contents"]) == 1
    assert s["contents"][0]["node_id"] == "valid"


def test_build_normalizes_unknown_as_to_link(engine):
    """An unknown ``as`` value falls back to ``link`` (so a malformed
    initial-contents list doesn't accidentally fire the auto-flip)."""
    engine.spawn("tx4", "ToolboxNode", params={
        "contents": [{"node_id": "n1", "as": "weirdo"}],
    })
    assert engine.nodes["tx4"].state["contents"][0]["as"] == "link"


# ---------- list / add / remove verbs ----------


def _dispatch(engine, node_id, verb, payload=None):
    """Direct handle_action call — bypasses engine.actions.dispatch_action
    (which requires a source connection for item validation). Toolbox
    verbs are renderer-scoped; payload feeds straight through."""
    n = engine.nodes[node_id]
    return engine.types["ToolboxNode"].handle_action(
        n.state, verb, payload or {}, engine, n,
    )


def test_list_empty(engine):
    engine.spawn("tx_list", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_list", "list")
    assert d["contents"] == []


def test_add_link_form_appends_no_auto_flip(engine):
    engine.spawn("tx_add", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_add", "add", {"node_id": "n1", "as": "link"})
    assert d["last_add"]["added"] is True
    assert d["last_add"]["index"] == 0
    assert "auto_flip" not in d  # link adds NEVER trigger flip
    assert engine.nodes["tx_add"].state["contents"] == [
        {"node_id": "n1", "as": "link", "child_kind": ""},
    ]


def test_add_rendered_form_with_unknown_kind_is_ambiguous(engine):
    """First rendered add with no inference rule fires the auto_flip
    hint with triggered=False + reason = ambiguous."""
    engine.spawn("tx_ambig", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_ambig", "add", {
        "node_id": "n1", "as": "rendered", "child_kind": "NeverHeardOfKind",
    })
    assert d["last_add"]["added"] is True
    assert "auto_flip" in d
    assert d["auto_flip"]["triggered"] is False
    assert "ambiguous" in d["auto_flip"]["reason"].lower()


def test_add_empty_node_id_rejected(engine):
    engine.spawn("tx_empty", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_empty", "add", {"node_id": ""})
    assert d["last_add"]["added"] is False
    assert engine.nodes["tx_empty"].state["contents"] == []


def test_add_invalid_as_rejected(engine):
    engine.spawn("tx_bad_as", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_bad_as", "add", {
        "node_id": "n1", "as": "neither-link-nor-rendered",
    })
    assert d["last_add"]["added"] is False
    assert engine.nodes["tx_bad_as"].state["contents"] == []


def test_remove_by_node_id(engine):
    engine.spawn("tx_rm", "ToolboxNode", params={})
    _dispatch(engine, "tx_rm", "add", {"node_id": "n1", "as": "link"})
    _dispatch(engine, "tx_rm", "add", {"node_id": "n2", "as": "link"})
    d = _dispatch(engine, "tx_rm", "remove", {"node_id": "n1"})
    assert d["last_remove"]["removed"] is True
    contents = engine.nodes["tx_rm"].state["contents"]
    assert len(contents) == 1
    assert contents[0]["node_id"] == "n2"


def test_remove_unknown_node_id(engine):
    engine.spawn("tx_rm2", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_rm2", "remove", {"node_id": "never-added"})
    assert d["last_remove"]["removed"] is False


# ---------- up / down / move / delete (verb shape from idea_queue) ----------


def test_up_swaps_with_previous(engine):
    engine.spawn("tx_up", "ToolboxNode", params={})
    for nid in ("a", "b", "c"):
        _dispatch(engine, "tx_up", "add", {"node_id": nid, "as": "link"})
    _dispatch(engine, "tx_up", "up", {"index": 2})  # swap c with b
    ids = [c["node_id"] for c in engine.nodes["tx_up"].state["contents"]]
    assert ids == ["a", "c", "b"]


def test_down_swaps_with_next(engine):
    engine.spawn("tx_dn", "ToolboxNode", params={})
    for nid in ("a", "b", "c"):
        _dispatch(engine, "tx_dn", "add", {"node_id": nid, "as": "link"})
    _dispatch(engine, "tx_dn", "down", {"index": 0})  # swap a with b
    ids = [c["node_id"] for c in engine.nodes["tx_dn"].state["contents"]]
    assert ids == ["b", "a", "c"]


def test_up_at_top_refuses(engine):
    engine.spawn("tx_top", "ToolboxNode", params={})
    _dispatch(engine, "tx_top", "add", {"node_id": "only", "as": "link"})
    d = _dispatch(engine, "tx_top", "up", {"index": 0})
    assert d["last_up"]["moved"] is False


def test_down_at_bottom_refuses(engine):
    engine.spawn("tx_bot", "ToolboxNode", params={})
    _dispatch(engine, "tx_bot", "add", {"node_id": "a", "as": "link"})
    d = _dispatch(engine, "tx_bot", "down", {"index": 0})
    assert d["last_down"]["moved"] is False


def test_move_swaps_arbitrary_indices(engine):
    engine.spawn("tx_mv", "ToolboxNode", params={})
    for nid in ("a", "b", "c", "d"):
        _dispatch(engine, "tx_mv", "add", {"node_id": nid, "as": "link"})
    _dispatch(engine, "tx_mv", "move", {"i": 0, "j": 3})
    ids = [c["node_id"] for c in engine.nodes["tx_mv"].state["contents"]]
    assert ids == ["d", "b", "c", "a"]


def test_delete_by_index(engine):
    engine.spawn("tx_del", "ToolboxNode", params={})
    for nid in ("keep1", "drop", "keep2"):
        _dispatch(engine, "tx_del", "add", {"node_id": nid, "as": "link"})
    d = _dispatch(engine, "tx_del", "delete", {"index": 1})
    assert d["last_delete"]["deleted"] is True
    ids = [c["node_id"] for c in engine.nodes["tx_del"].state["contents"]]
    assert ids == ["keep1", "keep2"]


def test_delete_out_of_range(engine):
    engine.spawn("tx_oor", "ToolboxNode", params={})
    d = _dispatch(engine, "tx_oor", "delete", {"index": 999})
    assert d["last_delete"]["deleted"] is False


def test_unknown_action_returns_none(engine):
    engine.spawn("tx_unknown", "ToolboxNode", params={})
    n = engine.nodes["tx_unknown"]
    out = engine.types["ToolboxNode"].handle_action(
        n.state, "nonexistent", {}, engine, n,
    )
    assert out is None


# ---------- emit + describe ----------


def test_emit_returns_channels(engine, view):
    engine.spawn("tx_emit", "ToolboxNode", params={"title": "Hi"})
    n = engine.nodes["tx_emit"]
    ch = engine.types["ToolboxNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n),
    )
    assert "color" in ch and "depth" in ch
    assert ch["color"].shape == (view.height, view.width, 3)


def test_describe_counts_link_and_rendered_separately(engine):
    engine.spawn("tx_desc", "ToolboxNode", params={
        "title": "Test",
        "contents": [
            {"node_id": "a", "as": "link"},
            {"node_id": "b", "as": "link"},
            {"node_id": "c", "as": "rendered", "child_kind": "ButtonNode"},
        ],
    })
    n = engine.nodes["tx_desc"]
    text = engine.types["ToolboxNode"].describe(
        n.state, EmitContext(engine=engine, node=n)
    )
    assert "Test" in text
    assert "link=2" in text
    assert "rendered=1" in text
    assert "contents=3" in text
