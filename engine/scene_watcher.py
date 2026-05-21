"""SceneWatcher — live-reload for ``scenes/*.json`` on edit.

Closes the bare-minimum-criterion-4 gap surfaced by the 2026-05-21
audit: the existing :class:`engine.file_watcher.FileWatcher` covers
``node_types/`` and ``renderers/`` Python files, but ``scenes/*.json``
edits are invisible to a running engine. A maintainer who edits
``scenes/workflow_view.json`` to add or rewire a node has to restart
the program — exactly the failure the criterion forbids.

This watcher fills the gap. It polls the project's ``scenes/``
directory on the same cadence as the Python-file watcher, tracks
mtime per JSON file, and on a modified-event for the currently-loaded
scene calls :meth:`engine.core.Engine.load_scene` followed by
:meth:`Engine.precompute`. New scene files are noticed but not
auto-loaded — adding a new scene shouldn't switch the active scene
behind the maintainer's back. The maintainer dispatches
``scene.load <name>`` (or clicks the picker) to load.

Worst-case race: the maintainer's editor writes the JSON in two passes
(write zero-byte stub, then write contents), the watcher fires between
the two writes, and ``json.loads`` raises. The handler catches the
exception, records it on ``engine.errors``, and continues — the next
poll re-fires and succeeds once the file is whole. No retry-loop is
needed because the polling cadence is its own retry. Tests cover the
race directly.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Dict, List, Optional, Tuple

if TYPE_CHECKING:  # pragma: no cover
    from engine.core import Engine


class SceneWatcher:
    """Polls ``scenes/*.json`` and reloads the active scene on edit.

    Lifecycle mirrors :class:`FileWatcher`: ``start()`` runs a daemon
    poll thread; ``stop()`` joins; ``poll_once()`` is a synchronous
    single-pass useful for tests.

    Constructor parameters:
      - ``engine`` — the live Engine the loaded scene came from.
      - ``scenes_dir`` — directory to watch. Defaults to
        ``engine.root_dir / "scenes"``.
      - ``poll_interval_s`` — polling cadence; matches FileWatcher's
        default of 0.2s.
      - ``on_event`` — optional callback ``(kind, name, path)`` for
        ``"new" / "modified" / "deleted" / "error"`` events.

    The watcher reads the engine's currently-loaded scene from
    ``engine.cache["__view_state__"]["scene_loader_main"]["current_scene"]``
    when one is set, falling back to scanning ``engine.scene_path`` if
    present. A modified-event for any other scene file is recorded but
    does not trigger a reload.
    """

    def __init__(
        self,
        engine: "Engine",
        scenes_dir: Optional[Path] = None,
        poll_interval_s: float = 0.2,
        on_event: Optional[Callable[[str, str, Path], None]] = None,
    ):
        self.engine = engine
        self.scenes_dir = Path(scenes_dir) if scenes_dir else (engine.root_dir / "scenes")
        self.poll_interval_s = float(poll_interval_s)
        self.on_event = on_event
        self._mtimes: Dict[str, float] = {}
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._seed_initial_state()

    # ----- public API -----

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, timeout_s: float = 2.0) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout_s)
            self._thread = None

    def poll_once(self) -> List[Tuple[str, str, Path]]:
        events: List[Tuple[str, str, Path]] = []
        if not self.scenes_dir.exists():
            return events

        current_files: Dict[str, Path] = {}
        for json_file in self.scenes_dir.glob("*.json"):
            if json_file.name.startswith("_"):
                continue
            current_files[str(json_file)] = json_file

        active = self._active_scene_name()

        for path_str, json_file in current_files.items():
            try:
                mtime = json_file.stat().st_mtime
            except OSError:
                continue
            prev_mtime = self._mtimes.get(path_str)
            if prev_mtime is None:
                self._mtimes[path_str] = mtime
                events.append(("new", json_file.name, json_file))
                self._notify("new", json_file.name, json_file)
            elif mtime > prev_mtime:
                self._mtimes[path_str] = mtime
                if json_file.name == active:
                    self._reload_active(json_file, events)
                else:
                    events.append(("modified", json_file.name, json_file))
                    self._notify("modified", json_file.name, json_file)

        # Deletions are recorded but not actioned (the engine keeps the
        # in-memory scene; the deletion is the maintainer's decision and
        # the next load picks up the absence).
        for path_str in list(self._mtimes.keys()):
            if path_str not in current_files:
                json_file = Path(path_str)
                events.append(("deleted", json_file.name, json_file))
                self._notify("deleted", json_file.name, json_file)
                del self._mtimes[path_str]

        return events

    # ----- internals -----

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.poll_once()
            except Exception as exc:
                self.engine.errors.append(f"scene_watcher.poll_once: {exc}")
            self._stop_event.wait(self.poll_interval_s)

    def _seed_initial_state(self) -> None:
        if not self.scenes_dir.exists():
            return
        for json_file in self.scenes_dir.glob("*.json"):
            if json_file.name.startswith("_"):
                continue
            try:
                self._mtimes[str(json_file)] = json_file.stat().st_mtime
            except OSError:
                continue

    def _active_scene_name(self) -> Optional[str]:
        """Resolve the currently-loaded scene name from engine state.

        First the scene_loader_main view-state (set by ``scene.load``),
        then engine.scene_path (set by load_scene), else None.
        """
        view_states = self.engine.cache.get("__view_state__") or {}
        loader_view = view_states.get("scene_loader_main") or {}
        current = loader_view.get("current_scene")
        if isinstance(current, str) and current:
            return current
        scene_path = getattr(self.engine, "scene_path", None)
        if scene_path:
            return Path(scene_path).name
        return None

    def _reload_active(
        self,
        json_file: Path,
        events: List[Tuple[str, str, Path]],
    ) -> None:
        """Reload the active scene; catch JSON-half-written races."""
        try:
            self.engine.load_scene(json_file)
            self.engine.precompute()
        except Exception as exc:
            # Record but don't crash — the next poll retries.
            self.engine.errors.append(
                f"scene_watcher.reload {json_file.name}: {exc}"
            )
            events.append(("error", json_file.name, json_file))
            self._notify("error", json_file.name, json_file)
            return
        events.append(("modified", json_file.name, json_file))
        self._notify("modified", json_file.name, json_file)

    def _notify(self, event_kind: str, name: str, path: Path) -> None:
        if self.on_event is None:
            return
        try:
            self.on_event(event_kind, name, path)
        except Exception:
            pass
