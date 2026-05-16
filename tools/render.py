"""
CLI: render a scene to a bundle directory.

Usage:
    python -m tools.render <scene_path> [--output <dir>]

Loads the scene, runs precompute, calls assemble, writes the bundle.
The bundle directory matches the painterly module engine's input contract.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from engine import Engine, View, look_at, write_bundle


def main(argv=None):
    parser = argparse.ArgumentParser(description="Render an Apeiron scene to a bundle.")
    parser.add_argument("scene", type=Path, help="Path to scene .json")
    parser.add_argument("--output", type=Path, default=Path("output"),
                        help="Output bundle directory")
    parser.add_argument("--root", type=str, default=None,
                        help="Override the scene's declared root node id")
    args = parser.parse_args(argv)

    root_dir = Path(__file__).parent.parent.resolve()
    engine = Engine(root_dir=root_dir)
    engine.discover()
    if engine.errors:
        print("[discover warnings]")
        for e in engine.errors:
            print(f"  {e}")

    scene_data = json.loads(args.scene.read_text())
    root_id = engine.load_scene(args.scene)
    root_id = args.root or root_id

    # Build the View from the scene metadata
    view_meta = scene_data.get("view", {})
    width = int(view_meta.get("width", 256))
    height = int(view_meta.get("height", 256))
    position = np.asarray(view_meta.get("position", [3.0, 2.0, 5.0]), dtype=np.float64)
    if "orientation" in view_meta:
        orientation = np.asarray(view_meta["orientation"], dtype=np.float64).reshape(3, 3)
    else:
        target = np.asarray(view_meta.get("look_at", [0.0, 0.0, 0.0]), dtype=np.float64)
        orientation = look_at(position, target)

    view = View(
        position=position,
        orientation=orientation,
        scale=float(view_meta.get("scale", 1.0)),
        width=width,
        height=height,
        fov_y_radians=float(view_meta.get("fov_y_radians", np.pi / 4)),
    )

    engine.precompute()
    channels = engine.assemble(root_id, view)

    output = write_bundle(channels, args.output, view=view,
                          scene_meta={"scene": str(args.scene), "root": root_id})
    print(f"wrote bundle: {output}")
    if "text" in channels and isinstance(channels["text"], str):
        text_path = output / "text.txt"
        text_path.write_text(channels["text"])
        print(f"text output:  {text_path}")

    if engine.errors:
        print("\n[engine warnings]")
        for e in engine.errors:
            print(f"  {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
