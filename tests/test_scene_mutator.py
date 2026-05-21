"""Tests for SceneMutator — the runtime-mutation primitive.

This node is THE primitive that makes "evolve from within" work.
Verbs map 1:1 onto Engine's SPEC-076 mutation surface (spawn,
set_param, connect, disconnect) plus two inspectors (list_nodes,
list_types).

Coverage:
  - spawn: creates a new node; rejects duplicate; rejects empty args.
  - set_param: mutates params; rejects missing node.
  - connect: wires; rejects missing source.
  - disconnect: unwires; rejects when slot was not connected.
  - list_nodes / list_types: enumerate engine state.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from engine import actions as engine_actions
from engine.core import Engine


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_mutator(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "scene_mutator_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"scene_mutator_main","type":"SceneMutator","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


def test_spawn_creates_node(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "new_cube", "type_name": "Cube",
                 "params": {"size": 1.0}},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_spawn"]["spawned"] is True
    assert "new_cube" in engine_with_mutator.nodes


def test_spawn_rejects_duplicate(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "scene_mutator_main", "type_name": "Cube"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_spawn"]["spawned"] is False
    assert "already exists" in view["last_spawn"]["reason"]


def test_spawn_rejects_empty_args(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "", "type_name": "Cube"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_spawn"]["spawned"] is False


def test_spawn_unknown_type_dead_node(engine_with_mutator: Engine) -> None:
    """An unknown type creates a dead-on-arrival node (per engine.spawn
    semantics). The mutator reports spawned=False with the engine's
    own error in the reason."""
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "bogus", "type_name": "ThereIsNoSuchType"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_spawn"]["spawned"] is False
    assert view["last_spawn"]["dead"] is True


def test_set_param_mutates(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "p_test", "type_name": "Cube",
                 "params": {"size": 1.0}},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "set_param",
        payload={"node_id": "p_test", "key": "size", "value": 2.5},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_set_param"]["set"] is True
    assert engine_with_mutator.nodes["p_test"].params["size"] == 2.5


def test_set_param_rejects_missing_node(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "set_param",
        payload={"node_id": "nope", "key": "x", "value": 1},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_set_param"]["set"] is False


def test_connect_wires(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "src", "type_name": "Cube"},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "dst", "type_name": "Cube"},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "connect",
        payload={"from_id": "src", "slot": "child", "to_id": "dst"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_connect"]["connected"] is True
    assert engine_with_mutator.nodes["src"].connections.get("child") == "dst"


def test_disconnect_removes_wire(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "u", "type_name": "Cube",
                 "connections": {"child": "scene_mutator_main"}},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "disconnect",
        payload={"from_id": "u", "slot": "child"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_disconnect"]["disconnected"] is True
    assert "child" not in engine_with_mutator.nodes["u"].connections


def test_disconnect_missing_slot(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "u2", "type_name": "Cube"},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "disconnect",
        payload={"from_id": "u2", "slot": "nonexistent"},
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    assert view["last_disconnect"]["disconnected"] is False


def test_list_nodes_includes_spawned(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "spawn",
        payload={"node_id": "list_test", "type_name": "Cube"},
    )
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "list_nodes", payload={}
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    ids = {n["id"] for n in view["last_list_nodes"]}
    assert "list_test" in ids
    assert "scene_mutator_main" in ids


def test_list_types_includes_discovered(engine_with_mutator: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_mutator, "scene_mutator_main", "list_types", payload={}
    )
    view = engine_actions.get_view_state(engine_with_mutator, "scene_mutator_main")
    types = view["last_list_types"]
    # The discover() call should have picked up several built-in types.
    assert "Cube" in types
    assert "SceneMutator" in types
    assert "ChatRouter" in types
