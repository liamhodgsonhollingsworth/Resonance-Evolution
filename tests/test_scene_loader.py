"""Tests for the SceneLoader node-type.

The fourth lift in the architectural arc (after chat_router v1 +
session cluster + chat_router v2 + inbox_echo). Provides list/load/
current verbs via engine.actions.dispatch_action so any surface or
MCP-tool caller dispatches one action instead of reimplementing the
file-glob + load + precompute sequence.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from engine import actions as engine_actions
from engine.core import Engine


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_loader(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "scene_loader_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"scene_loader_main","type":"SceneLoader","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


def test_list_returns_scenes(engine_with_loader: Engine) -> None:
    engine_with_loader.cache["__workflow__"] = {
        "session_manager": None, "inbox": None,
        "apeiron_root": REPO_ROOT,
    }
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    # The Apeiron repo's scenes/ should contain workflow_view.json plus others.
    assert "workflow_view.json" in view["scenes"]
    assert view["error"] is None


def test_list_fails_without_workflow_root(engine_with_loader: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    assert view["scenes"] == []
    assert "apeiron_root" in view["error"]


def test_load_unknown_scene_fails_gracefully(engine_with_loader: Engine) -> None:
    engine_with_loader.cache["__workflow__"] = {
        "session_manager": None, "inbox": None,
        "apeiron_root": REPO_ROOT,
    }
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "load",
        payload={"name": "nonexistent_scene"},
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    assert view["last_load"]["loaded"] is False
    assert "not found" in view["last_load"]["reason"]


def test_load_with_empty_name_fails(engine_with_loader: Engine) -> None:
    engine_with_loader.cache["__workflow__"] = {
        "session_manager": None, "inbox": None,
        "apeiron_root": REPO_ROOT,
    }
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "load",
        payload={"name": ""},
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    assert view["last_load"]["loaded"] is False
    assert "empty name" in view["last_load"]["reason"]


def test_load_real_scene_succeeds(engine_with_loader: Engine) -> None:
    engine_with_loader.cache["__workflow__"] = {
        "session_manager": None, "inbox": None,
        "apeiron_root": REPO_ROOT,
    }
    # hello_cube.json exists in Apeiron/scenes/ and is minimal.
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "load",
        payload={"name": "hello_cube"},
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    assert view["last_load"]["loaded"] is True
    assert view["last_load"]["scene"] == "hello_cube.json"
    assert view["current_scene"] == "hello_cube.json"


def test_current_returns_loaded_scene_after_load(engine_with_loader: Engine) -> None:
    engine_with_loader.cache["__workflow__"] = {
        "session_manager": None, "inbox": None,
        "apeiron_root": REPO_ROOT,
    }
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "load",
        payload={"name": "hello_cube"},
    )
    engine_actions.dispatch_action(
        engine_with_loader, "scene_loader_main", "current", payload={}
    )
    view = engine_actions.get_view_state(engine_with_loader, "scene_loader_main")
    assert view["last_current"] == "hello_cube.json"
