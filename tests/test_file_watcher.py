"""
End-to-end tests for the file-watcher feasibility proof.

Verifies the load-bearing claim of the workflow-from-within-Apeiron
plan: a new node-type file written to node_types/ at runtime is picked
up by the engine without restart, becomes spawnable, and the spawned
instance emits cleanly.

This is the mechanical proof of the maintainer's directive "claude
code generate new code and modules to be loaded in real time without
having to restart the program."
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View, look_at  # noqa: E402
from engine.file_watcher import FileWatcher  # noqa: E402


@pytest.fixture
def engine():
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def _write_new_node_type(node_types_dir: Path, type_name: str, color_rgb=(1.0, 0.5, 0.0)) -> Path:
    """Write a minimal valid node-type file to node_types/<type_name>.py.
    Returns the path."""
    file_path = node_types_dir / f"{type_name}.py"
    file_path.write_text(f'''"""
Auto-generated node-type for the file-watcher feasibility test.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="{type_name.capitalize()}",
        version="1.0",
        renderer_id="raster",
        inputs={{"size": "float"}},
        outputs={{"color": "rgb_image", "depth": "depth_image"}},
        description="Auto-generated test node-type for file-watcher.",
    )


def build(params):
    return {{"size": float(params.get("size", 1.0))}}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    w, h = view.width, view.height
    color = np.zeros((h, w, 3), dtype=np.float32)
    color[:] = [{color_rgb[0]}, {color_rgb[1]}, {color_rgb[2]}]
    depth = np.full((h, w), 0.5, dtype=np.float32)
    return {{"color": color, "depth": depth}}


def describe(state, ctx: EmitContext) -> str:
    return f"{type_name.capitalize()} test-node id={{ctx.node.id}}"
''', encoding="utf-8")
    return file_path


def test_file_watcher_picks_up_new_node_type(engine, tmp_path):
    """
    The load-bearing demo:
    1. Engine starts. WatchedTesttype is NOT registered.
    2. File-watcher starts (polling).
    3. We write node_types/watchedtesttype.py to disk.
    4. We poll once.
    5. WatchedTesttype is now registered.
    6. We spawn one; it emits cleanly.
    7. All without engine restart.
    """
    watcher = FileWatcher(engine, poll_interval_s=10.0)  # high interval; we drive manually
    assert "Watchedtesttype" not in engine.types

    node_types_dir = ROOT / "node_types"
    file_path = _write_new_node_type(node_types_dir, "watchedtesttype",
                                      color_rgb=(0.9, 0.3, 0.6))

    try:
        events = watcher.poll_once()
        new_events = [e for e in events if e[0] == "new" and e[1] == "Watchedtesttype"]
        assert len(new_events) >= 1, f"expected new-event for Watchedtesttype, got {events}"

        # The new type must now be registered and spawnable.
        assert "Watchedtesttype" in engine.types
        engine.spawn("wt1", "Watchedtesttype", params={"size": 1.0})
        assert not engine.nodes["wt1"].dead

        view = View(position=np.array([0.0, 0.0, 5.0]),
                    orientation=look_at(np.array([0.0, 0.0, 5.0]),
                                        np.array([0.0, 0.0, 0.0])),
                    width=32, height=32)
        channels = engine.assemble("wt1", view)
        assert "color" in channels
        # Color should match what the new module emits (close to 0.9, 0.3, 0.6).
        c = channels["color"]
        assert abs(c[0, 0, 0] - 0.9) < 0.01
        assert abs(c[0, 0, 1] - 0.3) < 0.01
        assert abs(c[0, 0, 2] - 0.6) < 0.01
    finally:
        watcher.stop()
        if file_path.exists():
            file_path.unlink()


def test_file_watcher_picks_up_modified_node_type(engine, tmp_path):
    """
    Hot-reload of an existing node-type. Write the file, register it,
    then modify the file (change the emitted color), poll, and verify
    the new color appears in the next emit.
    """
    watcher = FileWatcher(engine, poll_interval_s=10.0)
    node_types_dir = ROOT / "node_types"
    file_path = _write_new_node_type(node_types_dir, "reloadtesttype",
                                      color_rgb=(0.1, 0.1, 0.9))

    try:
        # First poll: new file appears.
        watcher.poll_once()
        assert "Reloadtesttype" in engine.types
        engine.spawn("rt1", "Reloadtesttype", params={"size": 1.0})

        view = View(width=16, height=16)
        ch1 = engine.assemble("rt1", view)
        assert abs(ch1["color"][0, 0, 2] - 0.9) < 0.01

        # Modify the file: change the color. Wait a tiny bit to ensure
        # mtime differs (filesystems vary in mtime resolution).
        time.sleep(0.05)
        _write_new_node_type(node_types_dir, "reloadtesttype",
                              color_rgb=(0.5, 0.7, 0.2))

        watcher.poll_once()
        # After reload, a freshly-spawned instance reflects the new code.
        engine.spawn("rt2", "Reloadtesttype", params={"size": 1.0})
        ch2 = engine.assemble("rt2", view)
        assert abs(ch2["color"][0, 0, 0] - 0.5) < 0.01
        assert abs(ch2["color"][0, 0, 1] - 0.7) < 0.01
        assert abs(ch2["color"][0, 0, 2] - 0.2) < 0.01
    finally:
        watcher.stop()
        if file_path.exists():
            file_path.unlink()


def test_file_watcher_handles_deletion(engine):
    """Deleted file produces a 'deleted' event; existing types stay
    registered (v1 deliberately doesn't unregister)."""
    watcher = FileWatcher(engine, poll_interval_s=10.0)
    node_types_dir = ROOT / "node_types"
    file_path = _write_new_node_type(node_types_dir, "deletetesttype",
                                      color_rgb=(0.3, 0.3, 0.3))

    try:
        watcher.poll_once()
        assert "Deletetesttype" in engine.types

        file_path.unlink()
        events = watcher.poll_once()
        deleted = [e for e in events if e[0] == "deleted"]
        assert len(deleted) >= 1
        # v1: registration stays. Future versions may unregister.
        assert "Deletetesttype" in engine.types
    finally:
        watcher.stop()
        if file_path.exists():
            file_path.unlink()


def test_file_watcher_seeded_state_doesnt_redundantly_load(engine):
    """First poll after start should produce zero events for already-
    registered node-types — the file-watcher's seeded state must include
    the engine's already-discovered files."""
    watcher = FileWatcher(engine, poll_interval_s=10.0)
    try:
        events = watcher.poll_once()
        # All events from this poll should be either "deleted" (unlikely on
        # a clean checkout) or empty. New and modified events would mean
        # the seed state didn't include already-discovered files.
        new_or_modified = [e for e in events if e[0] in ("new", "modified")]
        assert len(new_or_modified) == 0, (
            f"watcher's first poll redundantly fired {len(new_or_modified)} "
            f"events for already-discovered files: {new_or_modified[:3]}"
        )
    finally:
        watcher.stop()
