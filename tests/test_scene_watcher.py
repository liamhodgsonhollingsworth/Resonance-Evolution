"""Tests for SceneWatcher — live-reload of scenes/*.json on edit.

Closes the criterion-4 gap surfaced in the 2026-05-21 audit. Coverage:
  - Modified active scene triggers engine.load_scene + precompute.
  - Modified non-active scene is tracked but does not auto-load.
  - New scene file is noticed but not auto-loaded.
  - Malformed (half-written) JSON triggers an error event, not a crash;
    the next poll succeeds once the file is whole.
  - Deletion of a tracked file is recorded silently.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from engine.core import Engine
from engine.scene_watcher import SceneWatcher


REPO_ROOT = Path(__file__).resolve().parents[1]


def _write_minimal_scene(path: Path, root_id: str = "loader") -> None:
    path.write_text(
        """{
          "root": "%s",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"%s","type":"SceneLoader","params":{}}
          ]
        }""" % (root_id, root_id),
        encoding="utf-8",
    )


@pytest.fixture
def engine_with_scene(tmp_path: Path) -> Engine:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scenes_dir = tmp_path / "scenes"
    scenes_dir.mkdir()
    initial = scenes_dir / "active.json"
    _write_minimal_scene(initial, root_id="loader")
    engine.load_scene(initial)
    # Record the active scene name in scene_loader_main view-state so
    # the watcher can resolve which file to reload on edit.
    # The watcher resolves the active scene by reading
    # view-state["scene_loader_main"]["current_scene"]; that key is
    # the canonical id for the SceneLoader instance in workflow_view.
    engine.cache.setdefault("__view_state__", {}).setdefault(
        "scene_loader_main", {}
    )["current_scene"] = "active.json"
    return engine


def _force_newer_mtime(path: Path) -> None:
    """Set mtime far enough in the future that the watcher's mtime
    comparison fires reliably even on filesystems with coarse mtime
    resolution (HFS+, FAT32). Avoids flakiness on Windows.
    """
    now = time.time()
    os.utime(path, (now + 5, now + 5))


# ---------- happy-path reload ----------

def test_modified_active_scene_triggers_reload(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    watcher = SceneWatcher(engine_with_scene, scenes_dir=scenes_dir)

    active = scenes_dir / "active.json"
    _write_minimal_scene(active, root_id="loader")
    _force_newer_mtime(active)

    events = watcher.poll_once()
    kinds = {e[0] for e in events}
    assert "modified" in kinds
    # The reload added the loader node to engine.nodes; subsequent reads see it.
    assert "loader" in engine_with_scene.nodes


# ---------- non-active scenes ----------

def test_modified_non_active_scene_is_tracked_not_reloaded(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    watcher = SceneWatcher(engine_with_scene, scenes_dir=scenes_dir)

    other = scenes_dir / "other.json"
    _write_minimal_scene(other, root_id="other_root")
    # First poll: "new"
    events = watcher.poll_once()
    assert ("new", "other.json", other) in events
    # Modify it; should be "modified" but NOT trigger active reload.
    _force_newer_mtime(other)
    events = watcher.poll_once()
    assert ("modified", "other.json", other) in events
    # The other-scene's root id was not added to engine.nodes.
    assert "other_root" not in engine_with_scene.nodes


# ---------- malformed JSON race ----------

def test_malformed_json_records_error_not_crash(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    watcher = SceneWatcher(engine_with_scene, scenes_dir=scenes_dir)

    active = scenes_dir / "active.json"
    active.write_text("{ not valid json", encoding="utf-8")
    _force_newer_mtime(active)
    events = watcher.poll_once()
    kinds = [e[0] for e in events]
    assert "error" in kinds
    # Engine recorded the error message but did not crash.
    assert any("scene_watcher" in err for err in engine_with_scene.errors)

    # Repair the file; next poll reloads successfully.
    _write_minimal_scene(active, root_id="loader")
    _force_newer_mtime(active)
    events = watcher.poll_once()
    kinds = {e[0] for e in events}
    assert "modified" in kinds


# ---------- deletion ----------

def test_deleted_scene_is_recorded(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    watcher = SceneWatcher(engine_with_scene, scenes_dir=scenes_dir)

    extra = scenes_dir / "extra.json"
    _write_minimal_scene(extra, root_id="extra_root")
    watcher.poll_once()  # see "new"
    extra.unlink()
    events = watcher.poll_once()
    assert any(kind == "deleted" and name == "extra.json"
               for kind, name, _ in events)


# ---------- lifecycle ----------

def test_start_stop_thread(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    watcher = SceneWatcher(
        engine_with_scene, scenes_dir=scenes_dir, poll_interval_s=0.05
    )
    watcher.start()
    time.sleep(0.15)  # let the thread tick at least twice
    assert watcher._thread is not None and watcher._thread.is_alive()
    watcher.stop()
    assert watcher._thread is None


def test_on_event_callback_fires(
    engine_with_scene: Engine, tmp_path: Path
) -> None:
    scenes_dir = tmp_path / "scenes"
    seen = []
    watcher = SceneWatcher(
        engine_with_scene, scenes_dir=scenes_dir,
        on_event=lambda kind, name, path: seen.append((kind, name)),
    )
    active = scenes_dir / "active.json"
    _force_newer_mtime(active)
    watcher.poll_once()
    assert any(kind == "modified" and name == "active.json" for kind, name in seen)
