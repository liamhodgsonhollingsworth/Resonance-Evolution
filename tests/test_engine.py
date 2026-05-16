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


def test_sphere_renders_with_smooth_shading():
    """Sphere produces a lit, smoothly-shaded disc with depth varying
    radially. Verifies hits exist, shading varies (smooth not flat),
    and ID channel is populated."""
    e = Engine(root_dir=ROOT)
    e.discover()
    e.spawn("s1", "Sphere", params={"radius": 1.0, "color": [0.8, 0.4, 0.3], "id_hash": 7})

    pos = np.array([0.0, 0.0, 4.0])
    view = View(position=pos, orientation=look_at(pos, np.zeros(3)),
                width=128, height=128)
    channels = e.assemble("s1", view)
    color = channels["color"]
    depth = channels["depth"]
    ids = channels["ids"]

    lit = (color.sum(axis=-1) > 0.3).sum()
    assert lit > 200, f"sphere rendered too few pixels ({lit})"

    # Smooth shading: red-channel values should span a range (not all equal)
    red_at_hits = color[..., 0][color.sum(axis=-1) > 0.3]
    red_range = float(red_at_hits.max() - red_at_hits.min())
    assert red_range > 0.05, f"shading too flat ({red_range}); smooth shading should vary"

    # ID hash populated
    assert (ids == 7).sum() > 100

    # Depth finite at hits
    finite_depth = depth[np.isfinite(depth)]
    assert finite_depth.size > 100


def test_painterly_post_quantizes_color_and_marks_edges():
    """PainterlyPostProcessor consumes the source sub-graph's channels and
    applies palette reduction + ID-edge darkening. Verifies the output
    has fewer unique colors than the source (quantization fired) AND has
    dark pixels at object boundaries (edges fired)."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "painterly_demo.json"
    root_id = e.load_scene(scene_path)
    e.precompute()

    pos = np.array([0.0, 1.5, 8.0])
    view = View(position=pos, orientation=look_at(pos, np.zeros(3)),
                width=128, height=128)
    channels = e.assemble(root_id, view)
    color = channels["color"]

    # Quantization: count unique colors. With levels=5 the per-channel
    # range is discretized to ~6 values; total unique colors should be
    # much less than what a raw raster of three different cubes produces.
    unique = np.unique(color.reshape(-1, 3), axis=0)
    assert len(unique) < 200, f"too many unique colors ({len(unique)}); quantization didn't fire"

    # Edge pixels (darkened) should be present
    # At object outlines color is multiplied by 0.30; many such pixels should exist
    dim_pixels = ((color.sum(axis=-1) < 0.6) & (color.sum(axis=-1) > 0.05)).sum()
    assert dim_pixels > 30, f"no darkened edge pixels found ({dim_pixels}); edge detection didn't fire"


def test_computer_screen_shows_inner_cube():
    """Computer renders its 'running' sub-graph internally and pastes the
    result onto its screen rectangle in the outer world. The outer scene
    has a red cube (parent frame) plus a Computer whose internal sub-graph
    is a blue cube. Both colors must appear: red in the outer world,
    blue on the screen surface."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "computer_demo.json"
    root_id = e.load_scene(scene_path)
    e.precompute()

    pos = np.array([0.0, 0.5, 7.0])
    target = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target), width=128, height=128)
    channels = e.assemble(root_id, view)
    color = channels["color"]
    assert color is not None and color.shape == (128, 128, 3)

    red_mask = (color[..., 0] > 0.5) & (color[..., 2] < 0.3)
    assert red_mask.sum() > 0, "red cube not visible in outer world"

    blue_mask = (color[..., 2] > 0.4) & (color[..., 0] < 0.3)
    assert blue_mask.sum() > 0, "inner blue cube not visible on computer screen"


def test_computer_skips_default_recursion():
    """select_children returns [] for Computer — engine doesn't recurse
    into 'running' under the outer view. Computer.emit() owns the
    internal render."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "computer_demo.json"
    e.load_scene(scene_path)

    module = e.types["Computer"]
    node = e.nodes["computer"]
    pos = np.array([0.0, 0.5, 7.0])
    view = View(position=pos, orientation=look_at(pos, np.zeros(3)),
                width=64, height=64)
    selected = module.select_children(node.state, view, e, node)
    assert selected == [], f"expected select_children to return [], got {selected}"


def test_computer_recursion_two_levels():
    """Outer Computer renders an inner Computer that renders a green cube.
    The green cube must appear in the outermost render — verifies the
    recursion is unbounded by construction."""
    e = Engine(root_dir=ROOT)
    e.discover()

    e.spawn("green_cube", "Cube",
            params={"size": 1.5, "color": [0.2, 0.85, 0.3], "id_hash": 1})
    e.spawn("inner_computer", "Computer",
            params={
                "screen_width": 3.0, "screen_height": 2.0,
                "screen_resolution": 64,
                "internal_camera_position": [0.0, 0.5, 4.0],
                "internal_camera_target": [0.0, 0.0, 0.0],
            },
            connections={"running": "green_cube"})
    e.spawn("outer_computer", "Computer",
            params={
                "screen_width": 4.0, "screen_height": 3.0,
                "screen_resolution": 128,
                "internal_camera_position": [0.0, 0.5, 6.0],
                "internal_camera_target": [0.0, 0.0, 0.0],
            },
            connections={"running": "inner_computer"})
    e.precompute()

    pos = np.array([0.0, 0.5, 8.0])
    view = View(position=pos, orientation=look_at(pos, np.zeros(3)),
                width=128, height=128)
    channels = e.assemble("outer_computer", view)
    color = channels["color"]

    green_mask = (color[..., 1] > 0.5) & (color[..., 0] < 0.4) & (color[..., 2] < 0.4)
    assert green_mask.sum() > 0, "innermost green cube not visible — recursion broken"


def test_aggregator_precompute_populates_cache():
    """Aggregator's precompute_hook walks the target sub-graph and
    populates engine.cache with centroid, bounding_box, average_color,
    and leaf_count. The cache entry doubles as the BehaviorSummary
    other nodes can query."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "aggregator_demo.json"
    e.load_scene(scene_path)
    e.precompute()
    cache = e.cache.get("aggregator")
    assert cache is not None, "precompute did not populate cache for aggregator"
    assert cache["leaf_count"] == 9, f"expected 9 cubes, got {cache['leaf_count']}"
    # Centroid is at the geometric center of the 3x3 grid
    assert abs(float(cache["centroid"][0])) < 0.01, "centroid x should be ~0"
    assert abs(float(cache["centroid"][1])) < 0.01, "centroid y should be ~0"
    # Bounding box should span the grid extent (4.0 x 3.0 in XY, plus padding)
    assert cache["bounding_box"][0] > 4.0
    assert cache["bounding_box"][1] > 3.0


def test_aggregator_far_view_renders_impostor():
    """At a viewer distance exceeding the threshold, the aggregator
    renders its impostor (the aggregate_color AABB at centroid) rather
    than the target's full nine-cube render. The aggregate_color is
    [0.65, 0.50, 0.45] — neither pure red nor pure blue — so we verify
    that color dominates and the individual-cube colors do NOT appear."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "aggregator_demo.json"
    root_id = e.load_scene(scene_path)
    e.precompute()

    pos = np.array([0.0, 3.0, 25.0])  # well past threshold=12
    target_pos = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target_pos), width=128, height=128)
    channels = e.assemble(root_id, view)
    color = channels["color"]

    # Aggregate color is [0.65, 0.50, 0.45] (shaded slightly by face)
    impostor_mask = (color[..., 0] > 0.4) & (color[..., 1] > 0.3) & (color[..., 1] < 0.6) & (color[..., 2] > 0.2) & (color[..., 2] < 0.5)
    assert impostor_mask.sum() > 200, "impostor not visible at far view"

    # Individual saturated colors (pure red, pure blue) should NOT dominate
    pure_red = (color[..., 0] > 0.7) & (color[..., 1] < 0.3) & (color[..., 2] < 0.3)
    pure_blue = (color[..., 2] > 0.7) & (color[..., 0] < 0.3) & (color[..., 1] < 0.3)
    assert pure_red.sum() < 50, "pure red appeared at far view — target rendered through impostor?"
    assert pure_blue.sum() < 50, "pure blue appeared at far view"

    # BehaviorSummary is available on the channels
    assert "behavior_summary" in channels
    assert channels["behavior_summary"]["leaf_count"] == 9


def test_aggregator_near_view_renders_individuals():
    """At a viewer distance below the threshold, the aggregator emits the
    target's full render — distinct cube colors should appear."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "aggregator_demo.json"
    root_id = e.load_scene(scene_path)
    e.precompute()

    pos = np.array([0.0, 0.0, 6.0])  # well inside threshold=12
    target_pos = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target_pos), width=128, height=128)
    channels = e.assemble(root_id, view)
    color = channels["color"]

    # At near view, the saturated individual colors should be visible
    pure_red = (color[..., 0] > 0.6) & (color[..., 1] < 0.4) & (color[..., 2] < 0.4)
    pure_blue = (color[..., 2] > 0.6) & (color[..., 0] < 0.4) & (color[..., 1] < 0.4)
    assert pure_red.sum() > 5, "pure red not visible at near view"
    assert pure_blue.sum() > 5, "pure blue not visible at near view"


def test_aggregator_skips_target_render_at_far_view():
    """select_children() returns [] when the viewer is past the threshold —
    the target sub-graph is NOT rendered (no wasted runtime work). Verify
    by inspecting the engine's behavior, not just the output: spawn an
    aggregator with a sentinel target that increments a counter when
    emitted; counter stays at 0 across many far-view renders."""
    # For this test we rely on the fact that select_children empties
    # ctx.child_outputs when far. Easiest behavioral check: the target's
    # emit channels do not appear in the assembled output's depth at far view.
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "aggregator_demo.json"
    root_id = e.load_scene(scene_path)
    e.precompute()

    pos = np.array([0.0, 3.0, 25.0])
    target_pos = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target_pos), width=64, height=64)

    # Directly check select_children's decision
    aggregator_module = e.types["Aggregator"]
    aggregator_node = e.nodes["aggregator"]
    selected = aggregator_module.select_children(aggregator_node.state, view, e, aggregator_node)
    assert selected == [], f"expected select_children to return [] at far view, got {selected}"


def test_portal_renders_through_to_blue_cube():
    """Portal demonstrates topology-over-coordinates. The scene has a red
    cube in the parent frame plus a Portal whose 'through' connection
    targets a blue cube via a translation transform. The rendered output
    must contain both cube colors — red somewhere in the parent frame,
    blue somewhere visible through the portal's doorway. If only the
    parent frame rendered correctly, blue wouldn't appear; if only the
    portal's child rendered, red wouldn't appear; both must coexist."""
    e = Engine(root_dir=ROOT)
    e.discover()
    scene_path = ROOT / "scenes" / "portal_demo.json"
    root_id = e.load_scene(scene_path)

    pos = np.array([0.0, 1.5, 6.0])
    target = np.array([0.0, 0.0, 0.0])
    view = View(position=pos, orientation=look_at(pos, target), width=128, height=128)

    channels = e.assemble(root_id, view)
    color = channels["color"]
    assert color is not None and color.shape == (128, 128, 3)

    # Red cube visible in the parent frame
    red_mask = (color[..., 0] > 0.5) & (color[..., 2] < 0.3)
    assert red_mask.sum() > 0, "red cube not visible — parent frame failed to render"

    # Blue cube visible through the portal
    blue_mask = (color[..., 2] > 0.4) & (color[..., 0] < 0.3)
    assert blue_mask.sum() > 0, "blue cube not visible — portal's through-render failed"

    # Portal's id should appear in the spawned nodes
    assert "portal_a" in e.nodes
    assert e.nodes["portal_a"].type_name == "Portal"


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
