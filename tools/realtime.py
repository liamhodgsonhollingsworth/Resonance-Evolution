"""
CLI: open an Apeiron scene in an interactive realtime window.

Usage:
    python -m tools.realtime <scene_path> [--root <id>] [--backend tk]
                              [--width 800] [--height 600]
                              [--max-frames N] [--fps 60]

Loads the scene, opens a window via the selected backend, and runs the
realtime driver loop. WASD + mouse-look move the camera; Escape toggles
WorkflowView mode (panels ↔ full-render) when the scene root is a
WorkflowView, otherwise it quits. Close the window with X to quit.

The driver itself is in :mod:`engine.realtime`. The backend defaults to
``tk`` (stdlib via tkinter). A pygame backend can be added later without
changing the driver.

Headless callers can pass ``--max-frames 1`` to run a single frame and
exit cleanly — useful for smoke-testing on CI.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

import numpy as np

from engine import Engine, View, look_at
from engine.realtime import RealtimeDriver, available_backends, make_backend


def _build_view_from_scene(scene_data: dict, width: int, height: int) -> View:
    view_meta = scene_data.get("view", {})
    w = int(view_meta.get("width", width))
    h = int(view_meta.get("height", height))
    position = np.asarray(
        view_meta.get("position", [3.0, 2.0, 5.0]), dtype=np.float64
    )
    if "orientation" in view_meta:
        orientation = np.asarray(view_meta["orientation"], dtype=np.float64).reshape(3, 3)
    else:
        target = np.asarray(view_meta.get("look_at", [0.0, 0.0, 0.0]), dtype=np.float64)
        orientation = look_at(position, target)
    return View(
        position=position,
        orientation=orientation,
        scale=float(view_meta.get("scale", 1.0)),
        width=w,
        height=h,
        fov_y_radians=float(view_meta.get("fov_y_radians", np.pi / 4)),
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Open an Apeiron scene in an interactive realtime window."
    )
    parser.add_argument("scene", type=Path, help="Path to scene .json")
    parser.add_argument("--root", type=str, default=None,
                        help="Override the scene's root node id")
    parser.add_argument("--backend", type=str, default=None,
                        help="Windowing backend: tk (default if available)")
    parser.add_argument("--width", type=int, default=800)
    parser.add_argument("--height", type=int, default=600)
    parser.add_argument("--max-frames", type=int, default=None,
                        help="Run for N frames then exit (for testing).")
    parser.add_argument("--fps", type=int, default=60,
                        help="Target frame rate; 0 disables sleep between frames.")
    args = parser.parse_args(argv)

    if args.backend is None:
        backends = available_backends()
        if not backends:
            print(
                "no realtime backend available. install pygame, or run with "
                "a Python build that includes tkinter.",
                file=sys.stderr,
            )
            return 2
    try:
        backend = make_backend(args.backend)
    except RuntimeError as e:
        print(f"backend error: {e}", file=sys.stderr)
        return 2

    root_dir = Path(__file__).parent.parent.resolve()
    engine = Engine(root_dir=root_dir)
    engine.discover()
    if engine.errors:
        print("[discover warnings]", file=sys.stderr)
        for err in engine.errors:
            print(f"  {err}", file=sys.stderr)

    scene_data = json.loads(args.scene.read_text())
    declared_root = engine.load_scene(args.scene)
    root_id = args.root or declared_root

    view = _build_view_from_scene(scene_data, args.width, args.height)
    engine.precompute()

    frame_budget = 0.0 if args.fps <= 0 else (1.0 / float(args.fps))
    driver = RealtimeDriver(
        engine=engine,
        root_id=root_id,
        view=view,
        frame_budget_s=frame_budget,
    )

    backend.open(width=args.width, height=args.height, title=f"Apeiron — {args.scene.name}")
    print(
        f"[realtime] backend={type(backend).__name__} scene={args.scene} root={root_id}",
        file=sys.stderr,
    )
    print(
        "[realtime] WASD = move, mouse = look, scroll = zoom, T = chat, "
        "Esc = WorkflowView toggle / quit. Close window to exit.",
        file=sys.stderr,
    )
    rendered = driver.run(backend, max_frames=args.max_frames)
    print(f"[realtime] rendered {rendered} frame(s)", file=sys.stderr)

    if engine.errors:
        print("\n[engine warnings]", file=sys.stderr)
        for err in engine.errors:
            print(f"  {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
