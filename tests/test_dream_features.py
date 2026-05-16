"""
Tests for the dream-mode feature skeletons:
- View extension fields (gravity_mode, gravity_up, time)
- engine/input.py bindings + mutation application
- engine/inverse.py invert_edit dispatch
- engine.sim_precompute() walk
- DimensionN + ProjectorN composition (4D hypercube renders)
- Seed + Generator composition + invert_hook dispatch
- GravityField precompute_hook registration + active_field lookup
- KeyBindings load
- SimulationProbe sim_precompute_hook
- ChatInterpreter parsing
- The three new demo scenes load and assemble without errors
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View, look_at  # noqa: E402
from engine.input import (  # noqa: E402
    Bindings, BindingContext, InputEvent, ViewMutation, apply_mutation,
)


@pytest.fixture
def engine():
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


@pytest.fixture
def view_centered():
    pos = np.array([0.0, 1.0, 5.0])
    target = np.array([0.0, 0.0, 0.0])
    return View(position=pos, orientation=look_at(pos, target), width=64, height=64)


# ---------------------------------------------------------------------------
# View extension
# ---------------------------------------------------------------------------


def test_view_defaults_preserve_existing_behavior():
    v = View()
    assert v.gravity_mode == "world"
    assert np.allclose(v.gravity_up, [0.0, 1.0, 0.0])
    assert v.time == 0.0


def test_view_extension_fields_overridable():
    v = View(gravity_mode="free", gravity_up=np.array([0, 0, 1]), time=1.25)
    assert v.gravity_mode == "free"
    assert np.allclose(v.gravity_up, [0, 0, 1])
    assert v.time == 1.25


# ---------------------------------------------------------------------------
# Input bindings
# ---------------------------------------------------------------------------


def test_default_bindings_recognize_minecraft_controls():
    b = Bindings.default()
    ctx = BindingContext()
    ev = InputEvent(kind="key_down", key="w", timestamp=0.0)
    mutations = b.resolve(ev, ctx)
    assert len(mutations) >= 1
    assert any(m.delta_position is not None for m in mutations)


def test_scroll_zoom_produces_log_scale_mutation():
    b = Bindings.default()
    ctx = BindingContext()
    ev = InputEvent(kind="scroll", dy=1.0)
    mutations = b.resolve(ev, ctx)
    assert any(m.delta_scale != 0.0 for m in mutations)


def test_double_tap_space_toggles_gravity_mode():
    b = Bindings.default()
    ctx = BindingContext()
    v = View()
    ctx.current_view = v

    # First tap: should be a jump (no gravity toggle).
    ev1 = InputEvent(kind="key_down", key="space", timestamp=0.0)
    mutations1 = b.resolve(ev1, ctx)
    assert not any(m.set_gravity_mode for m in mutations1)
    ctx.last_press_time["space"] = 0.0

    # Second tap within window: should toggle gravity.
    ev2 = InputEvent(kind="key_down", key="space", timestamp=0.1)
    mutations2 = b.resolve(ev2, ctx)
    assert any(m.set_gravity_mode == "free" for m in mutations2)


def test_apply_mutation_translates_in_local_frame():
    v = View(position=np.array([0.0, 0.0, 0.0]))
    m = ViewMutation(delta_position=np.array([0.0, 0.0, -1.0]))  # local forward
    v2 = apply_mutation(v, m)
    # Default orientation is identity, so local forward (-Z) is world (-Z)
    assert np.allclose(v2.position, [0.0, 0.0, -1.0])


def test_apply_mutation_rotates_orientation():
    v = View()
    m = ViewMutation(delta_yaw=np.pi / 2)
    v2 = apply_mutation(v, m)
    # Yawing 90° in world rotates local -Z to +X (or -X depending on sign).
    forward = -v2.orientation[:, 2]
    assert abs(forward[0]) > 0.5, f"expected x-component dominance, got {forward}"


def test_apply_mutation_scale_is_multiplicative():
    v = View(scale=1.0)
    m = ViewMutation(delta_scale=np.log(2.0))
    v2 = apply_mutation(v, m)
    assert abs(v2.scale - 2.0) < 1e-6


# ---------------------------------------------------------------------------
# DimensionN + ProjectorN
# ---------------------------------------------------------------------------


def test_dimension_n_registered(engine):
    assert "DimensionN" in engine.types
    assert "ProjectorN" in engine.types


def test_dimension_n_hypercube_produces_16_verts_and_32_edges(engine):
    engine.spawn("t", "DimensionN", params={"dims": 4, "shape": "hypercube"})
    state = engine.nodes["t"].state
    assert state["verts_nd"].shape == (16, 4)
    assert state["edges"].shape == (32, 2)


def test_dimension_n_simplex(engine):
    engine.spawn("s", "DimensionN", params={"dims": 3, "shape": "simplex"})
    state = engine.nodes["s"].state
    assert state["verts_nd"].shape == (4, 3)  # tetrahedron
    assert state["edges"].shape == (6, 2)     # 4 choose 2


def test_dim4_cube_scene_assembles(engine, view_centered):
    root_id = engine.load_scene(ROOT / "scenes" / "dim4_cube_demo.json")
    channels = engine.assemble(root_id, view_centered)
    assert "color" in channels and "depth" in channels
    # The tesseract should produce non-background pixels somewhere.
    bg = np.array([0.04, 0.04, 0.10], dtype=np.float32)
    diff = np.linalg.norm(channels["color"] - bg, axis=-1)
    assert (diff > 0.05).any(), "tesseract produced no foreground pixels"


# ---------------------------------------------------------------------------
# Seed + Generator + invert
# ---------------------------------------------------------------------------


def test_seed_and_generator_registered(engine):
    assert "Seed" in engine.types
    assert "Generator" in engine.types


def test_generator_precomputes_specs_from_seed(engine):
    root_id = engine.load_scene(ROOT / "scenes" / "seed_world_demo.json")
    engine.precompute()
    cache = engine.cache.get("generator", {})
    specs = cache.get("specs", [])
    assert len(specs) == 3
    assert np.allclose(specs[0]["position"], [-2.0, 0.0, 0.0])


def test_generator_emit_renders_cubes(engine):
    root_id = engine.load_scene(ROOT / "scenes" / "seed_world_demo.json")
    engine.precompute()
    view = View(position=np.array([0.0, 2.0, 6.0]),
                orientation=look_at(np.array([0.0, 2.0, 6.0]),
                                    np.array([0.0, 0.0, 0.0])),
                width=64, height=64)
    channels = engine.assemble(root_id, view)
    assert channels["color"].max() > 0.0
    # All three cube positions should be visible.
    assert np.isfinite(channels["depth"]).sum() > 50


def test_invert_edit_updates_seed_and_re_precomputes(engine):
    root_id = engine.load_scene(ROOT / "scenes" / "seed_world_demo.json")
    engine.precompute()
    # Edit cube index 1 to a new position.
    handled = engine.invert_edit("generator", {
        "target": "cube_position",
        "index": 1,
        "new_value": [0.0, 3.0, 0.0],
    })
    assert handled
    new_specs = engine.cache["generator"]["specs"]
    assert np.allclose(new_specs[1]["position"], [0.0, 3.0, 0.0])
    seed_positions = engine.nodes["world_seed"].state["params"]["cube_positions"]
    assert list(seed_positions[1]) == [0.0, 3.0, 0.0]


def test_invert_edit_returns_false_when_no_inverter(engine):
    engine.spawn("c1", "Cube", params={"size": 1.0})
    handled = engine.invert_edit("c1", {"target": "anything"})
    assert handled is False


# ---------------------------------------------------------------------------
# GravityField
# ---------------------------------------------------------------------------


def test_gravity_field_registers_in_cache(engine):
    engine.spawn("g1", "GravityField",
                 params={"center": [0, 0, 0], "half_extent": [5, 5, 5],
                         "gravity": [0, -9.81, 0]})
    engine.precompute()
    fields = engine.cache.get("__gravity_fields__", [])
    assert any(f["node_id"] == "g1" for f in fields)


def test_gravity_field_active_lookup(engine):
    from node_types.gravity_field import active_field
    engine.spawn("g1", "GravityField",
                 params={"center": [0, 0, 0], "half_extent": [5, 5, 5],
                         "gravity": [0, -9.81, 0]})
    engine.precompute()
    f = active_field(engine, np.array([1.0, 2.0, 3.0]))
    assert f is not None
    assert f["node_id"] == "g1"
    f2 = active_field(engine, np.array([100.0, 0.0, 0.0]))
    assert f2 is None


# ---------------------------------------------------------------------------
# KeyBindings
# ---------------------------------------------------------------------------


def test_key_bindings_default_profile_loads(engine):
    engine.spawn("kb1", "KeyBindings", params={"profile": "minecraft"})
    state = engine.nodes["kb1"].state
    assert state["profile"] == "minecraft"
    assert len(state["bindings"].table) >= 4  # at least WASD


# ---------------------------------------------------------------------------
# SimulationProbe
# ---------------------------------------------------------------------------


def test_simulation_probe_registered(engine):
    assert "SimulationProbe" in engine.types


def test_sim_precompute_walks_without_step_targets(engine):
    engine.spawn("c1", "Cube", params={"size": 1.0})
    engine.spawn("p1", "SimulationProbe",
                 params={"horizon": 4, "dt": 0.1, "observed": ["c1"]})
    engine.sim_precompute()
    traj = engine.cache.get("p1__sim__")
    assert traj is not None
    assert traj["horizon"] == 4
    assert "c1" in traj["trajectories"]
    assert len(traj["trajectories"]["c1"]) == 4


# ---------------------------------------------------------------------------
# ChatInterpreter
# ---------------------------------------------------------------------------


def test_chat_interpreter_classifies_known_and_novel(engine, tmp_path):
    log = tmp_path / "chat.txt"
    log.write_text("describe scene\nmake_a_dragon\n", encoding="utf-8")
    engine.spawn("ci1", "ChatInterpreter",
                 params={"log_path": str(log), "claude_connected": False})
    engine.precompute()
    outcomes = engine.cache["ci1"]["outcomes"]
    kinds = [o["outcome"] for o in outcomes]
    assert "matched" in kinds
    assert "novel" in kinds


def test_chat_interpreter_writes_request_when_claude_connected(engine, tmp_path):
    log = tmp_path / "chat.txt"
    log.write_text("teleport_to_dream\n", encoding="utf-8")
    engine.spawn("ci2", "ChatInterpreter",
                 params={"log_path": str(log), "claude_connected": True})
    engine.precompute()
    after = log.read_text(encoding="utf-8")
    assert "requested: teleport_to_dream" in after


def test_chat_interpreter_writes_not_yet_learned_when_offline(engine, tmp_path):
    log = tmp_path / "chat.txt"
    log.write_text("teleport_to_dream\n", encoding="utf-8")
    engine.spawn("ci3", "ChatInterpreter",
                 params={"log_path": str(log), "claude_connected": False})
    engine.precompute()
    after = log.read_text(encoding="utf-8")
    assert "not yet learned: teleport_to_dream" in after


def test_dimension_n_hypercube_combinatorial_matches_naive(engine):
    """The O(V*N) hypercube edge generator must produce the same edges
    (as a set) the original O(V^2) version produced."""
    engine.spawn("hc", "DimensionN",
                 params={"dims": 5, "shape": "hypercube"})
    state = engine.nodes["hc"].state
    # 5-cube: 32 vertices, 5 * 32 / 2 = 80 edges.
    assert state["verts_nd"].shape == (32, 5)
    assert state["edges"].shape == (80, 2)
    # Every edge must connect vertices differing in exactly one coordinate.
    for (a, b) in state["edges"]:
        diff = np.sum(np.abs(state["verts_nd"][a] - state["verts_nd"][b]) > 1e-9)
        assert diff == 1, f"edge ({a},{b}) differs in {diff} coordinates"


# ---------------------------------------------------------------------------
# Demo scenes
# ---------------------------------------------------------------------------


def test_dream_topology_scene_assembles(engine):
    root_id = engine.load_scene(ROOT / "scenes" / "dream_topology_demo.json")
    view = View(position=np.array([0.0, 1.5, 4.5]),
                orientation=look_at(np.array([0.0, 1.5, 4.5]),
                                    np.array([0.0, 0.5, 0.0])),
                width=64, height=64)
    channels = engine.assemble(root_id, view)
    assert "color" in channels
    # No errors should accumulate on a clean assembly.
    assert all("dream_topology" not in e for e in engine.errors)


def test_all_new_scenes_load_without_errors(engine):
    for scene_name in ["dim4_cube_demo.json",
                       "seed_world_demo.json",
                       "dream_topology_demo.json"]:
        # Fresh engine per scene to avoid id collisions.
        e = Engine(root_dir=ROOT)
        e.discover()
        e.load_scene(ROOT / "scenes" / scene_name)
        e.precompute()
        # No catastrophic errors from these specific scenes.
        # (Discovery may register pre-existing errors, but our nodes
        # should not be among them.)
        sentinel_ids = {"projector", "tesseract", "generator",
                        "world_seed", "viewer_room"}
        for nid in sentinel_ids & set(e.nodes):
            assert not e.nodes[nid].dead, (
                f"{nid} in {scene_name} is dead: {e.nodes[nid].error}"
            )
