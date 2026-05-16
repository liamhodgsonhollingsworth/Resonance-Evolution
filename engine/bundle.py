"""
Bundle writer. Emits a directory matching the painterly module engine's
input contract:

    output/
      color.png
      depth.png
      normal.png      (optional — present if a normal channel was produced)
      ids.png         (optional — present if an ID channel was produced)
      manifest.json   (channel index + camera and scene metadata)

Channels not in this list pass through to manifest.json; downstream
consumers pick what they know about.
"""

import json
from pathlib import Path
from typing import Any, Dict
import numpy as np
from PIL import Image

from engine.node import Channels, View


def write_bundle(channels: Channels, output_dir: Path, view: View = None, scene_meta: Dict[str, Any] = None) -> Path:
    """Write a bundle directory. Returns the path it wrote to."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest: Dict[str, Any] = {
        "channels": {},
        "scene": scene_meta or {},
    }

    if view is not None:
        manifest["view"] = {
            "position": view.position.tolist() if hasattr(view.position, "tolist") else list(view.position),
            "orientation": view.orientation.tolist() if hasattr(view.orientation, "tolist") else view.orientation,
            "scale": float(view.scale),
            "width": int(view.width),
            "height": int(view.height),
            "fov_y_radians": float(view.fov_y_radians),
        }

    # Color
    if "color" in channels:
        color = _ensure_uint8_rgb(channels["color"])
        Image.fromarray(color, mode="RGB").save(output_dir / "color.png")
        manifest["channels"]["color"] = "color.png"

    # Depth — normalize to [0, 255] for visualization; keep the raw float in a sidecar
    if "depth" in channels:
        depth = np.asarray(channels["depth"], dtype=np.float32)
        depth_vis = _depth_to_uint8(depth)
        Image.fromarray(depth_vis, mode="L").save(output_dir / "depth.png")
        np.save(output_dir / "depth.npy", depth)
        manifest["channels"]["depth"] = "depth.png"
        manifest["channels"]["depth_raw"] = "depth.npy"

    # Normal (optional)
    if "normal" in channels:
        normal = channels["normal"]
        normal_vis = _ensure_uint8_rgb((np.asarray(normal, dtype=np.float32) + 1.0) / 2.0)
        Image.fromarray(normal_vis, mode="RGB").save(output_dir / "normal.png")
        manifest["channels"]["normal"] = "normal.png"

    # IDs (optional)
    if "ids" in channels:
        ids = np.asarray(channels["ids"], dtype=np.uint32)
        # Save as 16-bit grayscale if it fits; otherwise as raw npy.
        # PIL infers mode "I;16" from the uint16 dtype; passing mode= is deprecated.
        if ids.max() < 65536:
            Image.fromarray(ids.astype(np.uint16)).save(output_dir / "ids.png")
            manifest["channels"]["ids"] = "ids.png"
        else:
            np.save(output_dir / "ids.npy", ids)
            manifest["channels"]["ids"] = "ids.npy"

    # Text (optional, lands in manifest.json directly)
    if "text" in channels and isinstance(channels["text"], str):
        manifest["channels"]["text"] = channels["text"]

    # Any unknown channels go into manifest as descriptors
    for name, value in channels.items():
        if name in ("color", "depth", "normal", "ids", "text"):
            continue
        if isinstance(value, np.ndarray):
            np.save(output_dir / f"{name}.npy", value)
            manifest["channels"][name] = f"{name}.npy"
        elif isinstance(value, (str, int, float, bool, list, dict)):
            manifest["channels"][name] = value

    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return output_dir


def _ensure_uint8_rgb(arr) -> np.ndarray:
    arr = np.asarray(arr, dtype=np.float32)
    if arr.ndim == 2:
        arr = np.stack([arr, arr, arr], axis=-1)
    elif arr.shape[-1] == 4:
        arr = arr[..., :3]
    arr = np.clip(arr, 0.0, 1.0)
    return (arr * 255).astype(np.uint8)


def _depth_to_uint8(depth: np.ndarray) -> np.ndarray:
    finite = depth[np.isfinite(depth)]
    if finite.size == 0:
        return np.zeros_like(depth, dtype=np.uint8)
    lo, hi = float(finite.min()), float(finite.max())
    if hi - lo < 1e-9:
        return np.full(depth.shape, 128, dtype=np.uint8)
    normalized = np.where(np.isfinite(depth), (depth - lo) / (hi - lo), 1.0)
    return (np.clip(normalized, 0.0, 1.0) * 255).astype(np.uint8)
