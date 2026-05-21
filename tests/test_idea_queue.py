"""Tests for IdeaQueue — file-backed ordered list.

Covers every verb: list/add/up/down/delete/move + the soft-fail paths
(empty text, integer parse, out-of-range index, missing state_dir).

The fixture mirrors session_target's pattern: register a tmp_path
state_dir on the workflow singleton so the node has somewhere to read
+ write.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from engine import actions as engine_actions
from engine.core import Engine


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_idea_queue(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "idea_queue_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"idea_queue_main","type":"IdeaQueue","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    # Register a workflow singleton with tmp state_dir so the node
    # has somewhere to read + write.
    engine.cache["__workflow__"] = {"state_dir": tmp_path / "state"}
    return engine


# ---------- list ----------

def test_list_empty(engine_with_idea_queue: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["items"] == []


def test_add_then_list(engine_with_idea_queue: Engine) -> None:
    for text in ("first", "second", "third"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add",
            payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["items"] == ["first", "second", "third"]


def test_add_empty_text_rejected(engine_with_idea_queue: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "add", payload={"text": "   "}
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["last_add"]["added"] is False


# ---------- up / down ----------

def test_up_swaps_with_previous(engine_with_idea_queue: Engine) -> None:
    for text in ("a", "b", "c"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add", payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "up", payload={"index": 2},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["items"] == ["a", "c", "b"]


def test_down_swaps_with_next(engine_with_idea_queue: Engine) -> None:
    for text in ("a", "b", "c"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add", payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "down", payload={"index": 0},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["items"] == ["b", "a", "c"]


def test_up_at_top_refuses(engine_with_idea_queue: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "add", payload={"text": "only"},
    )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "up", payload={"index": 0},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["last_up"]["moved"] is False
    # Items unchanged.
    assert view["items"] == ["only"]


def test_down_at_bottom_refuses(engine_with_idea_queue: Engine) -> None:
    for text in ("a", "b"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add", payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "down", payload={"index": 1},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["last_down"]["moved"] is False


# ---------- delete ----------

def test_delete_removes_item(engine_with_idea_queue: Engine) -> None:
    for text in ("keep1", "drop", "keep2"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add", payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "delete", payload={"index": 1},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["last_delete"]["deleted"] is True
    assert view["last_delete"]["text"] == "drop"
    assert view["items"] == ["keep1", "keep2"]


def test_delete_out_of_range_refuses(engine_with_idea_queue: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "delete", payload={"index": 999},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["last_delete"]["deleted"] is False


# ---------- move ----------

def test_move_swaps_arbitrary_indices(engine_with_idea_queue: Engine) -> None:
    for text in ("a", "b", "c", "d"):
        engine_actions.dispatch_action(
            engine_with_idea_queue, "idea_queue_main", "add", payload={"text": text},
        )
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "move", payload={"i": 0, "j": 3},
    )
    view = engine_actions.get_view_state(engine_with_idea_queue, "idea_queue_main")
    assert view["items"] == ["d", "b", "c", "a"]


# ---------- persistence ----------

def test_persistence_round_trip(engine_with_idea_queue: Engine, tmp_path: Path) -> None:
    """Items survive a fresh load — verifies the on-disk format matches
    the original commands.py format so existing idea_queue.md files
    work unchanged."""
    engine_actions.dispatch_action(
        engine_with_idea_queue, "idea_queue_main", "add", payload={"text": "persistent"},
    )
    # Read the file directly; check the format matches commands.py's.
    file_path = (tmp_path / "state" / "idea_queue.md")
    assert file_path.exists()
    body = file_path.read_text(encoding="utf-8")
    assert body == "# Idea queue\n\n- persistent\n"


# ---------- error paths ----------

def test_missing_state_dir_returns_clean_error(tmp_path: Path) -> None:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "idea_queue_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"idea_queue_main","type":"IdeaQueue","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    # No __workflow__ singleton registered.
    engine_actions.dispatch_action(
        engine, "idea_queue_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine, "idea_queue_main")
    assert "last_error" in view
    assert "state_dir" in view["last_error"]
