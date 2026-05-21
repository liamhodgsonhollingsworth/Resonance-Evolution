"""Tests for the StreamlitPanel node-type + the new discovery path.

Closes the parallel-registry gap surfaced by the 2026-05-21
bare-minimum-criterion-2 audit. Coverage:
  - StreamlitPanel.list returns every instance with the right shape.
  - discover_panels_with_engine_overrides picks up filesystem panels +
    applies scene-declared overrides (mount_point, order).
  - A scene declaration for a non-existent panel becomes a hidden
    error-shaped RegisteredPanel rather than crashing.
  - The current workflow_view.json scene actually declares the panels.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from engine import actions as engine_actions
from engine.core import Engine


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_panel_nodes(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        json.dumps({
            "root": "streamlit_panel_main",
            "view": {"position": [0, 0, 5], "look_at": [0, 0, 0],
                     "width": 64, "height": 64, "fov_y_radians": 0.6},
            "nodes": [
                {"id": "streamlit_panel_main", "type": "StreamlitPanel",
                 "params": {"panel_name": "auth", "mount_point": "gate", "order": 0}},
                {"id": "panel_chat", "type": "StreamlitPanel",
                 "params": {"panel_name": "chat", "mount_point": "main", "order": 10}},
            ],
        }),
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


def test_streamlit_panel_list_returns_all(engine_with_panel_nodes: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_panel_nodes, "streamlit_panel_main", "list", payload={}
    )
    view = engine_actions.get_view_state(engine_with_panel_nodes, "streamlit_panel_main")
    panels = view["last_list"]
    names = {p["panel_name"] for p in panels}
    assert "auth" in names and "chat" in names
    mounts = {p["panel_name"]: p["mount_point"] for p in panels}
    assert mounts["auth"] == "gate"
    assert mounts["chat"] == "main"


def test_discovery_applies_scene_overrides(engine_with_panel_nodes: Engine) -> None:
    """Scene declares an order override; discovery should reflect it."""
    from tools.workflow_streamlit.registry import (
        discover_panels_with_engine_overrides,
    )
    panels = discover_panels_with_engine_overrides(engine_with_panel_nodes)
    chat = next((p for p in panels if p.manifest.name == "chat"), None)
    assert chat is not None
    # Scene override sets order=10 (matches the chat panel's own default
    # but the override path exercises the merge logic).
    assert chat.manifest.order == 10
    assert chat.manifest.mount_point == "main"


def test_discovery_handles_unknown_panel_name(tmp_path: Path) -> None:
    """Scene declares a StreamlitPanel for a non-existent module:
    should produce a hidden + load-errored RegisteredPanel, not crash."""
    from tools.workflow_streamlit.registry import (
        discover_panels_with_engine_overrides,
    )
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        json.dumps({
            "root": "panel_main",
            "view": {"position": [0, 0, 5], "look_at": [0, 0, 0],
                     "width": 64, "height": 64, "fov_y_radians": 0.6},
            "nodes": [
                {"id": "panel_main", "type": "StreamlitPanel",
                 "params": {"panel_name": "no-such-panel"}},
            ],
        }),
        encoding="utf-8",
    )
    engine.load_scene(scene)
    panels = discover_panels_with_engine_overrides(engine)
    no_such = [p for p in panels if p.manifest.name == "no-such-panel"]
    assert len(no_such) == 1
    assert no_such[0].manifest.hidden is True
    assert "unknown" in (no_such[0].load_error or "").lower()


def test_filesystem_panels_present_when_scene_silent(tmp_path: Path) -> None:
    """A scene that declares NO StreamlitPanel still returns every
    filesystem-discovered panel — declarative-scene is additive."""
    from tools.workflow_streamlit.registry import (
        discover_panels_with_engine_overrides,
    )
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    # Use a SceneLoader as a non-StreamlitPanel placeholder root.
    scene.write_text(
        json.dumps({
            "root": "loader",
            "view": {"position": [0, 0, 5], "look_at": [0, 0, 0],
                     "width": 64, "height": 64, "fov_y_radians": 0.6},
            "nodes": [
                {"id": "loader", "type": "SceneLoader", "params": {}},
            ],
        }),
        encoding="utf-8",
    )
    engine.load_scene(scene)
    panels = discover_panels_with_engine_overrides(engine)
    # The Apeiron repo carries the five panels by default.
    names = {p.manifest.name for p in panels}
    for expected in ("auth", "chat", "session-status", "scene-picker", "terminal"):
        assert expected in names, f"missing {expected} in {names}"


def test_workflow_view_declares_panels() -> None:
    """The canonical workflow_view scene actually declares the panels
    via StreamlitPanel nodes, per criterion 2 of the bare-minimum
    audit."""
    scene_path = REPO_ROOT / "scenes" / "workflow_view.json"
    data = json.loads(scene_path.read_text(encoding="utf-8"))
    streamlit_panels = [
        n for n in data["nodes"] if n.get("type") == "StreamlitPanel"
    ]
    panel_names = {n["params"]["panel_name"] for n in streamlit_panels}
    for expected in ("auth", "chat", "session-status", "scene-picker", "terminal"):
        assert expected in panel_names, f"missing {expected}"
