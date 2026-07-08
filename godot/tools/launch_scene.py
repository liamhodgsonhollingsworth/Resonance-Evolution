#!/usr/bin/env python3
"""Guaranteed-RENDER launcher for ANY Godot scene — the fix for the grey-screen-on-fresh-launch class.

ROOT CAUSE it fixes (visi-sonor grey screen, 2026-07-08): the project's primitives `extends Primitive`
(and reference other `class_name` types). At RUNTIME those globals resolve only via
`.godot/global_script_class_cache.cfg`, which Godot gitignores and the EDITOR (not a game launch)
regenerates. So a fresh checkout / a stale cache / a launch after `class_name`s changed →
"Could not resolve script ..." for every primitive → the scene root script fails to parse → its
`_ready` never runs → the viewport shows the flat grey default → GREY SCREEN.

THIS launcher makes a one-click launch faithful: it rebuilds the class cache (headless editor pass,
NO window) IF the cache is missing or older than the newest `.gd`, THEN opens the scene in the GUI.
The desktop shortcut and the resonance:// open-in-Godot watcher point at THIS (via `pythonw`, so no
console flashes — SPEC-619) instead of the raw GUI exe. Reusable for EVERY scene, so future one-click
launches inherit the fix instead of each re-hitting the grey screen.

USAGE:
    pythonw launch_scene.py res://demo_interactions.tscn          # the desktop-shortcut form (windowless)
    py -3 launch_scene.py res://X.tscn --force-rebuild            # always rebuild first
    py -3 launch_scene.py res://X.tscn --rebuild-only             # rebuild cache, do NOT open a window (CI/verify)
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve()
DEFAULT_PROJECT = HERE.parents[1]  # <re>/godot
GUI_EXE = os.environ.get("GODOT", r"C:/Users/Liam/godot/Godot_v4.6.3-stable_win64.exe")
CONSOLE_EXE = os.environ.get("GODOT_CONSOLE", r"C:/Users/Liam/godot/Godot_v4.6.3-stable_win64_console.exe")
CREATE_NO_WINDOW = 0x08000000  # windows: suppress the console for the headless rebuild pass


def _log(project: Path, msg: str) -> None:
    # windowless (pythonw) has no stdout — leave a breadcrumb on disk instead.
    try:
        (project / "artifacts").mkdir(parents=True, exist_ok=True)
        with open(project / "artifacts" / "launch_scene.log", "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def cache_is_stale(project: Path) -> bool:
    cache = project / ".godot" / "global_script_class_cache.cfg"
    if not cache.exists():
        return True
    cache_mtime = cache.stat().st_mtime
    # if any .gd is newer than the cache, a class_name may have moved/added → rebuild.
    for gd in project.rglob("*.gd"):
        if ".godot" in gd.parts:
            continue
        try:
            if gd.stat().st_mtime > cache_mtime:
                return True
        except OSError:
            continue
    return False


def rebuild_cache(project: Path) -> int:
    # a headless editor pass scans every script and (re)writes global_script_class_cache.cfg. No window.
    cmd = [CONSOLE_EXE, "--headless", "--path", str(project), "--editor", "--quit"]
    try:
        proc = subprocess.run(cmd, creationflags=CREATE_NO_WINDOW, capture_output=True,
                              text=True, timeout=180, encoding="utf-8", errors="replace")
        return proc.returncode
    except (subprocess.TimeoutExpired, OSError) as e:
        _log(project, f"rebuild_cache error: {e}")
        return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Launch a Godot scene with a guaranteed-fresh class cache.")
    ap.add_argument("scene", help="res:// scene to open (e.g. res://demo_interactions.tscn)")
    ap.add_argument("--project", default=str(DEFAULT_PROJECT), help="the godot/ project dir")
    ap.add_argument("--force-rebuild", action="store_true", help="rebuild the class cache even if fresh")
    ap.add_argument("--rebuild-only", action="store_true", help="rebuild the cache but do NOT open a window")
    ap.add_argument("--wait", action="store_true", help="block until the GUI process exits")
    args = ap.parse_args()

    project = Path(args.project)
    if args.force_rebuild or cache_is_stale(project):
        _log(project, f"cache stale/forced → rebuilding for {args.scene}")
        rc = rebuild_cache(project)
        _log(project, f"rebuild returncode={rc}")
    else:
        _log(project, f"cache fresh → skip rebuild for {args.scene}")

    if args.rebuild_only:
        return 0

    # the game window IS the intended visible window here (this is a user-initiated launch, not a daemon).
    gui = [GUI_EXE, "--path", str(project), args.scene]  # noqa: console-window
    _log(project, f"launching GUI: {args.scene}")
    if args.wait:
        return subprocess.run(gui).returncode
    subprocess.Popen(gui, close_fds=True)  # noqa: console-window
    return 0


if __name__ == "__main__":
    sys.exit(main())
