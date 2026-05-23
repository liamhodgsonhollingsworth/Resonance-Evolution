"""test_workflow_view_substrate_mirror.py — tests for the Apeiron-side
substrate-mirror precompute_hook on node_types/workflow_view.py
(brief 02 commit 1).

Covers:
- Opt-in behavior: without substrate_view_name, the hook returns an
  empty cache shape and never accesses the substrate. Pre-existing
  scenes are unaffected.
- Substrate import path: with substrate_view_name + substrate_nodes_dir
  set to a path containing a workflow_view substrate node, the hook
  pulls + caches positions.
- Graceful degrade: missing nodes_dir, missing view, malformed body —
  all surface as cache.error rather than crashing precompute.
- Append round-trip: publish a substrate workflow_view → spawn the
  Apeiron WorkflowView pointing at it → precompute → cache.positions
  reflects substrate state.
- Idempotent re-precompute: a second precompute_hook call yields the
  same cache when nothing has changed substrate-side.
- Supersession-follow: when substrate publishes a new supersession of
  the workflow_view, the next precompute picks up the new leaf.

The tests use the shared Engine fixture pattern from test_workflow_view.py.
They configure SUBSTRATE_PROJECT_ROOT to a tmp dir so substrate
operations write into the tmp store rather than the production Alethea-cc
nodes/ directory.

Per brief 02 per-module plan commit 1 + DS-F032 sub-spec.

Run:
    cd Apeiron && python -m pytest tests/test_workflow_view_substrate_mirror.py -v
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

# Substrate lives in Alethea-cc/substrate/. Add it to sys.path so the
# precompute_hook's lazy `from primitives import find, ...` resolves.
ALETHEA_CC_SUBSTRATE = (
    APEIRON_ROOT.parent / "Alethea" / "Alethea-cc" / "substrate"
)
if str(ALETHEA_CC_SUBSTRATE) not in sys.path:
    sys.path.insert(0, str(ALETHEA_CC_SUBSTRATE))

os.environ["ALETHEA_AUTO_NOTION_SYNC"] = "0"

from engine import Engine  # noqa: E402


SYNTHETIC_NODE_A = "sha256:" + "a" * 64
SYNTHETIC_NODE_B = "sha256:" + "b" * 64


def _make_workflow_view_node(body_positions: list[dict] | None = None) -> dict:
    """Construct a workflow_view substrate-shaped dict (for publish)."""
    from evaluator import compute_id  # type: ignore

    body = {
        "positions": list(body_positions) if body_positions else [],
        "default_paste_location": "end",
        "metadata": {
            "window": "50,20,20",
            "mode": "append-only",
            "surface": "test_surface",
        },
    }
    node: dict = {
        "name": "workflow_view_main",
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": body,
        "connections": [],
    }
    node["id"] = compute_id(node)
    return node


@pytest.fixture
def engine():
    e = Engine(root_dir=APEIRON_ROOT)
    e.discover()
    return e


# ---------------------------------------------------------------------------
# Opt-in: without substrate_view_name, the hook returns empty cache
# ---------------------------------------------------------------------------


def test_workflow_view_precompute_no_substrate_returns_empty_cache(engine):
    """Pre-existing scenes that do NOT set substrate_view_name continue
    to work as before. The hook returns an empty cache shape (positions=[],
    error=None) without touching the substrate."""
    engine.spawn("wv", "WorkflowView", params={"mode": "panels"})
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache is not None
    assert cache["positions"] == []
    assert cache["error"] is None
    assert cache["substrate_view_name"] == ""
    assert cache["substrate_id"] is None


def test_workflow_view_precompute_no_nodes_dir_surfaces_error(engine):
    """substrate_view_name set without substrate_nodes_dir → error in
    cache, positions empty. Pre-existing scenes don't trigger this; only
    misconfigured substrate-mirror setups do."""
    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
        },
    )
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache["positions"] == []
    assert "substrate_nodes_dir" in cache["error"]


def test_workflow_view_precompute_missing_nodes_dir_surfaces_error(
    engine, tmp_path
):
    """substrate_nodes_dir pointing at a non-existent path → error in
    cache, positions empty."""
    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
            "substrate_nodes_dir": str(tmp_path / "no_such_dir"),
        },
    )
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache["positions"] == []
    assert "does not exist" in cache["error"]


def test_workflow_view_precompute_missing_view_surfaces_error(
    engine, tmp_path
):
    """nodes_dir exists but no workflow_view with the named view → error
    in cache, positions empty."""
    tmp_path.mkdir(exist_ok=True)
    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "absent_view",
            "substrate_nodes_dir": str(tmp_path),
        },
    )
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache["positions"] == []
    assert "no substrate workflow_view found" in cache["error"]


# ---------------------------------------------------------------------------
# Happy-path mirror: substrate fixture exists → positions cached
# ---------------------------------------------------------------------------


def test_workflow_view_precompute_mirrors_empty_substrate(engine, tmp_path):
    """A published workflow_view substrate node with zero appends is
    cached as positions=[] + the substrate_id is recorded."""
    from primitives import publish  # type: ignore

    wv_node = _make_workflow_view_node()
    publish(wv_node, nodes_dir=tmp_path)

    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
            "substrate_nodes_dir": str(tmp_path),
        },
    )
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache["error"] is None
    assert cache["positions"] == []
    assert cache["substrate_id"] == wv_node["id"]
    assert cache["substrate_view_name"] == "workflow_view_main"
    assert cache["default_paste_location"] == "end"
    assert cache["metadata"]["mode"] == "append-only"


def test_workflow_view_precompute_mirrors_appended_substrate(engine, tmp_path):
    """A workflow_view with two appended entries propagates to the
    Apeiron-side cache verbatim — the source-of-truth shape."""
    from primitives import publish  # type: ignore

    wv_v1 = _make_workflow_view_node()
    publish(wv_v1, nodes_dir=tmp_path)

    # Two appends via the substrate's execute() — the canonical entry point.
    from primitives import execute  # type: ignore

    wv_v2 = execute(
        wv_v1,
        input={
            "action": "append",
            "content_node_id": SYNTHETIC_NODE_A,
            "provenance": {"source": "chat"},
            "appended_at": "2026-05-22T00:00:00Z",
            "appended_by": "test",
        },
    )
    publish(wv_v2, nodes_dir=tmp_path)
    wv_v3 = execute(
        wv_v2,
        input={
            "action": "append",
            "content_node_id": SYNTHETIC_NODE_B,
            "provenance": {"source": "paste"},
            "appended_at": "2026-05-22T00:01:00Z",
            "appended_by": "test",
        },
    )
    publish(wv_v3, nodes_dir=tmp_path)

    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
            "substrate_nodes_dir": str(tmp_path),
        },
    )
    engine.precompute()
    cache = engine.cache.get("wv")
    assert cache["error"] is None
    # The hook follows the forward chain to the leaf — picks v3, not v1.
    assert cache["substrate_id"] == wv_v3["id"]
    # Positions reflect the two appends in order.
    assert [e["node_id"] for e in cache["positions"]] == [
        SYNTHETIC_NODE_A,
        SYNTHETIC_NODE_B,
    ]
    # Provenance carried through to the Apeiron-side cache.
    assert cache["positions"][0]["provenance"]["source"] == "chat"
    assert cache["positions"][1]["provenance"]["source"] == "paste"


def test_workflow_view_precompute_is_idempotent(engine, tmp_path):
    """Re-running precompute when substrate state hasn't changed yields
    an identical cache."""
    from primitives import publish  # type: ignore

    wv_node = _make_workflow_view_node()
    publish(wv_node, nodes_dir=tmp_path)

    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
            "substrate_nodes_dir": str(tmp_path),
        },
    )
    engine.precompute()
    cache_first = dict(engine.cache.get("wv"))
    engine.precompute()
    cache_second = engine.cache.get("wv")
    assert cache_first == cache_second


def test_workflow_view_precompute_follows_supersession(engine, tmp_path):
    """After publishing a new supersession of the workflow_view, the
    next precompute pulls the leaf — substrate-as-source-of-truth."""
    from primitives import publish, execute  # type: ignore

    wv_v1 = _make_workflow_view_node()
    publish(wv_v1, nodes_dir=tmp_path)

    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
            "substrate_nodes_dir": str(tmp_path),
        },
    )
    engine.precompute()
    cache_before = engine.cache.get("wv")
    assert cache_before["substrate_id"] == wv_v1["id"]
    assert cache_before["positions"] == []

    # Append a node to the substrate.
    wv_v2 = execute(
        wv_v1,
        input={
            "action": "append",
            "content_node_id": SYNTHETIC_NODE_A,
            "provenance": {"source": "external_session"},
        },
    )
    publish(wv_v2, nodes_dir=tmp_path)

    # Re-precompute → cache picks up the new leaf.
    engine.precompute()
    cache_after = engine.cache.get("wv")
    assert cache_after["substrate_id"] == wv_v2["id"]
    assert [e["node_id"] for e in cache_after["positions"]] == [SYNTHETIC_NODE_A]


# ---------------------------------------------------------------------------
# Backward-compat: substrate mirror does NOT affect mode-toggling /
# select_children / describe semantics
# ---------------------------------------------------------------------------


def test_substrate_mirror_does_not_affect_select_children(engine):
    """The substrate mirror lives in cache only; the panel-composition
    behavior (select_children based on mode) is unchanged."""
    from engine import View
    from node_types import workflow_view

    engine.spawn("p", "ListRenderer", params={"title_text": "P"})
    engine.spawn("c", "ListRenderer", params={"title_text": "C"})
    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            # Substrate mirror enabled but pointed at empty dir; precompute
            # surfaces an error but select_children still works.
            "substrate_view_name": "workflow_view_main",
        },
        connections={"panel_a": "p", "chat_bar": "c"},
    )
    node = engine.nodes["wv"]
    selected = workflow_view.select_children(node.state, View(), engine, node)
    assert selected == ["panel_a", "chat_bar"]


def test_substrate_mirror_does_not_affect_set_mode(engine):
    """The set_mode mutator is unaffected by substrate-mirror state."""
    from node_types import workflow_view

    engine.spawn(
        "wv",
        "WorkflowView",
        params={
            "mode": "panels",
            "substrate_view_name": "workflow_view_main",
        },
    )
    node = engine.nodes["wv"]
    workflow_view.set_mode(node, "full_render")
    assert node.state["mode"] == "full_render"
    with pytest.raises(ValueError):
        workflow_view.set_mode(node, "nonsense")


def test_substrate_mirror_does_not_break_default_workflow_view_scene(engine):
    """The canonical workflow_view.json scene loads + renders without
    error even when the default params (no substrate_view_name) leave
    substrate mirror disabled — the cache shape is the empty shape."""
    import numpy as np
    from engine import View, look_at

    scene_path = APEIRON_ROOT / "scenes" / "workflow_view.json"
    if not scene_path.exists():
        pytest.skip("workflow_view.json scene not present in this checkout")
    engine.load_scene(scene_path)
    engine.precompute()

    # The workflow_view node has the empty-substrate cache because
    # substrate_view_name was not set in the scene JSON.
    wv_cache = engine.cache.get("workflow_view")
    assert wv_cache is not None
    assert wv_cache["positions"] == []
    assert wv_cache["error"] is None

    # Render still produces output.
    view = View(
        position=np.array([0.0, 0.0, 9.0]),
        orientation=look_at(
            np.array([0.0, 0.0, 9.0]), np.array([0.0, 0.0, 0.0])
        ),
        width=128,
        height=64,
        fov_y_radians=0.6,
    )
    channels = engine.assemble("workflow_view", view)
    assert channels["color"].sum() > 0
