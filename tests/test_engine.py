"""
Tests for the engine. Run with:
    pytest tests/

Covers:
- Discovery: the engine finds and registers node-types and renderers.
- Spawn: node instances are created from manifests; build failures isolate.
- Assemble: simple scenes render to channels.
- Bundle: writing a bundle produces the expected files.
- Module isolation: broken node-types fail without crashing the engine.
- Text-renderer: TextRenderer produces text output.
- Text testing tools: describe_scene, describe_view, summarize_bundle.
"""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

# Make the project root importable
ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View, look_at, write_bundle  # noqa: E402
from tools.text_test import (  # noqa: E402
    describe_scene, describe_view, summarize_bundle, dispatch_command, assert_visible,
)


@pytest.fixture
def engine():
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


@pytest.fixture
def hello_scene(engine):
    scene_path = ROOT / "scenes" / "hello_cube.json"
    root_id = engine.load_scene(scene_path)
    return engine, root_id


@pytest.fixture
def view_for_hello():
    pos = np.array([3.0, 2.0, 5.0])
    target = np.array([0.0, 0.0, 0.0])
    return View(position=pos, orientation=look_at(pos, target), width=64, height=64)


def test_discovery_finds_cube_and_group(engine):
    assert "Cube" in engine.types
    assert "Group" in engine.types
    assert "TextRenderer" in engine.types


def test_discovery_does_not_crash_on_broken_type(tmp_path, engine):
    bad_file = tmp_path / "bad.py"
    bad_file.write_text("def manifest(): raise RuntimeError('boom')\n")
    # Manually try to load — should record an error, not raise
    engine._load_node_type_file(bad_file, "node_types")
    assert any("bad.py" in e for e in engine.errors)


def test_spawn_creates_node(engine):
    engine.spawn("c1", "Cube", params={"size": 1.0})
    assert "c1" in engine.nodes
    assert not engine.nodes["c1"].dead


def test_spawn_unknown_type_marks_dead(engine):
    engine.spawn("c1", "NotARealType", params={})
    assert engine.nodes["c1"].dead
    assert "unknown type" in engine.nodes["c1"].error


def test_assemble_hello_scene(hello_scene, view_for_hello):
    engine, root_id = hello_scene
    channels = engine.assemble(root_id, view_for_hello)
    assert "color" in channels
    assert "depth" in channels
    # Some pixels should hit the cube
    depth = channels["depth"]
    finite = depth[np.isfinite(depth)]
    assert finite.size > 0, "no pixels hit the cube"
    # Color should have non-zero values where hit
    color = channels["color"]
    assert color.max() > 0.0


def test_bundle_writes_expected_files(tmp_path, hello_scene, view_for_hello):
    engine, root_id = hello_scene
    channels = engine.assemble(root_id, view_for_hello)
    out = tmp_path / "bundle"
    write_bundle(channels, out, view=view_for_hello)
    assert (out / "color.png").exists()
    assert (out / "depth.png").exists()
    assert (out / "manifest.json").exists()
    manifest = json.loads((out / "manifest.json").read_text())
    assert "color" in manifest["channels"]
    assert "depth" in manifest["channels"]


def test_describe_scene_walks_topology(hello_scene):
    engine, root_id = hello_scene
    text = describe_scene(engine, root_id)
    assert "Group" in text
    assert "Cube" in text
    assert root_id in text


def test_describe_view_produces_text(hello_scene, view_for_hello):
    engine, root_id = hello_scene
    text = describe_view(engine, root_id, view_for_hello)
    assert "SCENE:" in text
    assert "Cube" in text


def test_text_demo_scene_renders_text(engine):
    scene_path = ROOT / "scenes" / "text_demo.json"
    root_id = engine.load_scene(scene_path)
    pos = np.array([3.0, 2.0, 5.0])
    target = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target), width=64, height=24)
    channels = engine.assemble(root_id, view)
    assert "text" in channels
    text = channels["text"]
    assert "VIEW:" in text
    assert "SCENE:" in text
    assert "COMMANDS AVAILABLE:" in text


def test_dispatch_command_describe(hello_scene, view_for_hello):
    engine, _root = hello_scene
    result, _view = dispatch_command(engine, "describe cube_a", view=view_for_hello)
    assert "Cube" in result
    assert "cube_a" in result


def test_dispatch_command_list_types(hello_scene, view_for_hello):
    engine, _root = hello_scene
    result, _ = dispatch_command(engine, "list-types", view=view_for_hello)
    assert "Cube" in result
    assert "Group" in result
    assert "TextRenderer" in result


def test_dispatch_command_move_updates_view(hello_scene, view_for_hello):
    engine, _ = hello_scene
    _result, new_view = dispatch_command(engine, "move 1 0 0", view=view_for_hello)
    assert new_view.position[0] == view_for_hello.position[0] + 1.0


def test_dispatch_command_spawn_and_describe(hello_scene, view_for_hello):
    engine, _root = hello_scene
    result, _ = dispatch_command(engine, "spawn Cube new_cube size=0.5", view=view_for_hello)
    assert "spawned" in result
    assert "new_cube" in engine.nodes
    assert engine.nodes["new_cube"].state["size"] == 0.5


def test_assert_visible_cube_is_visible(hello_scene, view_for_hello):
    engine, root_id = hello_scene
    assert assert_visible(engine, root_id, view_for_hello, "Cube") is True


def test_summarize_bundle(tmp_path, hello_scene, view_for_hello):
    engine, root_id = hello_scene
    channels = engine.assemble(root_id, view_for_hello)
    out = tmp_path / "bundle"
    write_bundle(channels, out, view=view_for_hello)
    summary = summarize_bundle(out)
    assert "color" in summary
    assert "depth" in summary


def test_broken_node_type_isolated(engine, tmp_path):
    """A node-type whose emit() raises should not crash the engine — its
    instance is marked dead and the rest of the scene renders."""
    # Inject a broken node-type
    bad_file = ROOT / "node_types" / "_broken_test.py"
    bad_file.write_text(
        "from engine.node import Manifest\n"
        "def manifest():\n"
        "    return Manifest(name='BrokenTest', renderer_id='raster')\n"
        "def emit(state, view, ctx):\n"
        "    raise RuntimeError('deliberately broken for the test')\n"
    )
    try:
        engine._load_node_type_file(bad_file, "node_types")
        engine.spawn("broken", "BrokenTest", params={})
        # Build the scene around it
        engine.spawn("good_cube", "Cube", params={"size": 1.0})
        engine.spawn("root", "Group", connections={"broken_child": "broken", "good_child": "good_cube"})
        view = View(position=np.array([3.0, 2.0, 5.0]),
                    orientation=look_at(np.array([3.0, 2.0, 5.0]), np.zeros(3)),
                    width=32, height=32)
        channels = engine.assemble("root", view)
        # The broken node became dead
        assert engine.nodes["broken"].dead is True
        # But the good cube still rendered
        assert "color" in channels
        assert channels["color"].max() > 0.0
    finally:
        bad_file.unlink(missing_ok=True)
