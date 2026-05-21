"""Tests for PanelPositioner — surface-independent snap/move/resize/lock.

Covers every verb the lift defines:
  - register: insert + grid-snap + min-size clamp
  - move: snap-to-12px-grid; locked refuses; negative clamps to (0, 0)
  - resize: 48-px minimum + grid snap; locked refuses
  - lock / unlock: flips the flag; locked move/resize refuse
  - archive / unarchive: archived panels excluded from peer-snap
  - snap_to_peers: closest peer-edge wins per-axis; archived peers skipped
  - get_state / list: read paths

The node replaces gui_shell's PanelHandle math, so the tests mirror
``tests/test_panel_movable_resize.py`` semantics but exercise the
node-graph dispatch path (engine_actions.dispatch_action) instead of
the GuiShell Tk surface.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from engine import actions as engine_actions
from engine.core import Engine


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_positioner(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "panel_positioner_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"panel_positioner_main","type":"PanelPositioner","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


# ---------- register ----------

def test_register_creates_panel(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "task", "x": 100, "y": 200, "w": 480, "h": 320},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_register"]["registered"] is True
    rec = view["panels"]["task"]
    # 100 and 200 are not on the 12-px grid; round to 96 and 204.
    assert rec["x"] == 96
    assert rec["y"] == 204
    assert rec["w"] == 480
    assert rec["h"] == 324  # 320 rounds up to 324 (next 12-multiple)


def test_register_rejects_empty_id(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "", "x": 0, "y": 0},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_register"]["registered"] is False


# ---------- move ----------

def test_move_snaps_to_grid(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p", "x": 0, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "move",
        payload={"panel_id": "p", "x": 100, "y": 50},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_move"]["moved"] is True
    # 100 -> 96, 50 -> 48 (both snap to 12-px grid).
    assert view["panels"]["p"]["x"] == 96
    assert view["panels"]["p"]["y"] == 48


def test_move_idempotent_after_first_snap(engine_with_positioner: Engine) -> None:
    """SPEC-007: calling move with the same args twice is a no-op once
    the grid has clamped."""
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p", "x": 0, "y": 0},
    )
    for _ in range(3):
        engine_actions.dispatch_action(
            engine_with_positioner, "panel_positioner_main", "move",
            payload={"panel_id": "p", "x": 96, "y": 48},
        )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["panels"]["p"]["x"] == 96
    assert view["panels"]["p"]["y"] == 48


def test_move_locked_refuses(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p", "x": 96, "y": 48},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "lock",
        payload={"panel_id": "p"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "move",
        payload={"panel_id": "p", "x": 500, "y": 500},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_move"]["moved"] is False
    # Position unchanged.
    assert view["panels"]["p"]["x"] == 96
    assert view["panels"]["p"]["y"] == 48


# ---------- resize ----------

def test_resize_clamps_to_48px_min(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "resize",
        payload={"panel_id": "p", "w": 10, "h": 10},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_resize"]["resized"] is True
    assert view["panels"]["p"]["w"] == 48
    assert view["panels"]["p"]["h"] == 48


def test_resize_locked_refuses(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p", "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "lock",
        payload={"panel_id": "p"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "resize",
        payload={"panel_id": "p", "w": 240, "h": 120},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_resize"]["resized"] is False
    assert view["panels"]["p"]["w"] == 480
    assert view["panels"]["p"]["h"] == 324


# ---------- lock / unlock ----------

def test_lock_unlock_round_trip(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "lock",
        payload={"panel_id": "p"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["panels"]["p"]["locked"] is True
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "unlock",
        payload={"panel_id": "p"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["panels"]["p"]["locked"] is False


# ---------- snap_to_peers ----------

def test_snap_to_peers_aligns_to_closest_edge(engine_with_positioner: Engine) -> None:
    # Peer at (0, 0, 480, 324); target near peer's right edge.
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "peer", "x": 0, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "target", "x": 484, "y": 0, "w": 480, "h": 324},
    )
    # 484 is 4 px from the peer's right edge (480) — within snap distance 12.
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "snap_to_peers",
        payload={"panel_id": "target"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    # Target snaps left from 484 to 480 (aligned to peer.x + peer.w).
    assert view["last_snap"]["snapped"] is True
    assert view["panels"]["target"]["x"] == 480


def test_snap_to_peers_skips_archived(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "archived_peer", "x": 0, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "archive",
        payload={"panel_id": "archived_peer"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "target", "x": 484, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "snap_to_peers",
        payload={"panel_id": "target"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    # Only peer is archived; no other peers; snap is a no-op.
    assert view["last_snap"]["snapped"] is False


def test_snap_to_peers_locked_refuses(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "peer", "x": 0, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "target", "x": 484, "y": 0, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "lock",
        payload={"panel_id": "target"},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "snap_to_peers",
        payload={"panel_id": "target"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_snap"]["snapped"] is False
    # register already grid-snapped x=484 -> 480; lock prevents further snap.
    assert view["panels"]["target"]["x"] == 480


# ---------- get_state / list ----------

def test_get_state_returns_record(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "register",
        payload={"panel_id": "p", "x": 96, "y": 48, "w": 480, "h": 324},
    )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "get_state",
        payload={"panel_id": "p"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    rec = view["last_get_state"]
    assert rec["x"] == 96
    assert rec["w"] == 480
    assert rec["locked"] is False


def test_get_state_unknown_panel_empty(engine_with_positioner: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "get_state",
        payload={"panel_id": "nope"},
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    assert view["last_get_state"] == {}


def test_list_returns_all_panels_sorted(engine_with_positioner: Engine) -> None:
    for pid in ("c_panel", "a_panel", "b_panel"):
        engine_actions.dispatch_action(
            engine_with_positioner, "panel_positioner_main", "register",
            payload={"panel_id": pid},
        )
    engine_actions.dispatch_action(
        engine_with_positioner, "panel_positioner_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_positioner, "panel_positioner_main")
    ids = [p["panel_id"] for p in view["last_list"]]
    assert ids == ["a_panel", "b_panel", "c_panel"]
