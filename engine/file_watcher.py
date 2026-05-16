"""
File-watcher for hot-reloading node-types and renderers.

Closes the loop between Claude Code writing a new node-type file and the
engine seeing it without a restart. Polling-based — no external
dependency. Polling interval is small enough (~200ms default) for the
chat-driven workflow to feel immediate; the cost is negligible because
node-type directories are small (single-digit-to-low-double-digit files).

Architecture commitment satisfied: "Claude Code edits trigger
incremental rebuild of only the affected sub-graph" from
architecture.md's precomputation section. The file-watcher is the
mechanism: when a file changes, only its node-type's registration
updates; existing scene nodes survive the reload; precomputed cache
entries are NOT automatically invalidated by v1 — a future enhancement
walks the graph for affected instances and re-precomputes only those.

Usage:

    from engine import Engine
    from engine.file_watcher import FileWatcher

    engine = Engine(root_dir="...")
    engine.discover()
    watcher = FileWatcher(engine)
    watcher.start()
    # ... engine runs; new/edited files are picked up automatically ...
    watcher.stop()

For one-shot polling (no thread), call `watcher.poll_once()` directly.
The interactive renderer's main loop will call this between frames; the
demo CLI uses the threaded mode.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.core import Engine


class FileWatcher:
    """
    Polls node_types/ and renderers/ for new and modified .py files;
    dispatches reload to the engine when changes land.

    Tracks per-file mtime. A file that didn't exist on the previous poll
    is "new" and gets loaded via Engine._load_node_type_file. A file
    whose mtime changed is "modified" and gets reloaded via
    Engine.reload_type using the manifest()'s declared name. A file
    that was tracked but now missing is "deleted" — v1 logs and does
    not unregister (manifest names may still be in use; clean removal
    is future work tied to per-edit-creates-new-node semantics).
    """

    DEFAULT_KINDS = ("node_types", "renderers")

    def __init__(
        self,
        engine: "Engine",
        kinds: Tuple[str, ...] = DEFAULT_KINDS,
        poll_interval_s: float = 0.2,
        on_event: Optional[Callable[[str, str, Path], None]] = None,
    ):
        self.engine = engine
        self.kinds = kinds
        self.poll_interval_s = float(poll_interval_s)
        self.on_event = on_event  # (event_kind, type_name, path) -> None
        self._mtimes: Dict[str, float] = {}  # path str -> mtime
        self._path_to_type: Dict[str, str] = {}  # path str -> manifest name (for reload)
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

        # Seed the mtime map from the engine's current registration. After
        # discover() has run, every registered type has its file's current
        # mtime recorded as "known." First poll surfaces only changes since.
        self._seed_initial_state()

    # ----- public API -----

    def start(self) -> None:
        """Run the poll loop on a daemon thread."""
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self, timeout_s: float = 2.0) -> None:
        """Signal the thread to stop and join briefly."""
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout_s)
            self._thread = None

    def poll_once(self) -> List[Tuple[str, str, Path]]:
        """
        Single poll pass. Returns the list of events processed as
        (event_kind, type_name, path) triples. Useful for tests and for
        synchronous frame-loop integration where the watcher polls
        between frames rather than on its own thread.

        Event kinds: "new", "modified", "deleted".
        """
        events: List[Tuple[str, str, Path]] = []
        current_files: Dict[str, Path] = {}

        for kind in self.kinds:
            kind_dir = self.engine.root_dir / kind
            if not kind_dir.exists():
                continue
            for py_file in kind_dir.glob("*.py"):
                if py_file.name.startswith("_"):
                    continue
                current_files[str(py_file)] = py_file

        # New + modified
        for path_str, py_file in current_files.items():
            try:
                mtime = py_file.stat().st_mtime
            except OSError:
                continue
            prev_mtime = self._mtimes.get(path_str)
            if prev_mtime is None:
                # New file
                kind = self._kind_for_path(py_file)
                self._load_new(py_file, kind)
                self._mtimes[path_str] = mtime
                type_name = self._path_to_type.get(path_str, py_file.stem)
                events.append(("new", type_name, py_file))
                self._notify("new", type_name, py_file)
            elif mtime > prev_mtime:
                # Modified file
                type_name = self._path_to_type.get(path_str)
                if type_name is None:
                    # Was tracked but type lookup missed; treat as new.
                    kind = self._kind_for_path(py_file)
                    self._load_new(py_file, kind)
                    type_name = self._path_to_type.get(path_str, py_file.stem)
                else:
                    self.engine.reload_type(type_name)
                self._mtimes[path_str] = mtime
                events.append(("modified", type_name, py_file))
                self._notify("modified", type_name, py_file)

        # Deleted (tracked path no longer present)
        for path_str in list(self._mtimes.keys()):
            if path_str not in current_files:
                py_file = Path(path_str)
                type_name = self._path_to_type.get(path_str, py_file.stem)
                # v1: log the deletion; do not unregister.
                events.append(("deleted", type_name, py_file))
                self._notify("deleted", type_name, py_file)
                # Remove from tracking so re-creation is detected as "new".
                del self._mtimes[path_str]
                self._path_to_type.pop(path_str, None)

        return events

    # ----- internals -----

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.poll_once()
            except Exception as e:
                self.engine.errors.append(f"file_watcher.poll_once: {e}")
            self._stop_event.wait(self.poll_interval_s)

    def _seed_initial_state(self) -> None:
        """
        After engine.discover() has run, every currently-registered
        type came from some file. Record those files' mtimes so the
        first poll doesn't redundantly re-register them. Also build the
        path-to-type-name map needed for reload_type dispatch.
        """
        for kind in self.kinds:
            kind_dir = self.engine.root_dir / kind
            if not kind_dir.exists():
                continue
            for py_file in kind_dir.glob("*.py"):
                if py_file.name.startswith("_"):
                    continue
                path_str = str(py_file)
                try:
                    self._mtimes[path_str] = py_file.stat().st_mtime
                except OSError:
                    continue
                # Reverse-lookup the manifest name for this file from
                # the engine's registered types (matched by the
                # sys.modules name convention the engine uses).
                mod_name = f"apeiron_{kind}_{py_file.stem}"
                import sys
                mod = sys.modules.get(mod_name)
                if mod is not None and hasattr(mod, "manifest"):
                    try:
                        self._path_to_type[path_str] = mod.manifest().name
                    except Exception:
                        pass

    def _load_new(self, py_file: Path, kind: str) -> None:
        """Register a brand-new node-type file with the engine."""
        try:
            self.engine._load_node_type_file(py_file, kind)
            # Capture the manifest name so subsequent reloads can find it.
            import sys
            mod_name = f"apeiron_{kind}_{py_file.stem}"
            mod = sys.modules.get(mod_name)
            if mod is not None and hasattr(mod, "manifest"):
                try:
                    self._path_to_type[str(py_file)] = mod.manifest().name
                except Exception:
                    pass
        except Exception as e:
            self.engine.errors.append(
                f"file_watcher._load_new({py_file}): {e}"
            )

    def _kind_for_path(self, py_file: Path) -> str:
        """Return 'node_types' or 'renderers' depending on which dir the file is in."""
        parent = py_file.parent.name
        if parent in self.kinds:
            return parent
        return self.kinds[0]

    def _notify(self, event_kind: str, type_name: str, path: Path) -> None:
        if self.on_event is None:
            return
        try:
            self.on_event(event_kind, type_name, path)
        except Exception:
            pass


def watch_engine(engine: "Engine", **kwargs) -> FileWatcher:
    """Convenience constructor + start. Returns the running watcher."""
    w = FileWatcher(engine, **kwargs)
    w.start()
    return w
