"""Shared helpers for the raster presentation variants.

Per Decision A1 + per the existing-primitives audit recurring guidance:
visual variants compose against ``engine/screen.py`` for the
ray-cast/paste primitive AND share local helpers here for the
variant-specific math (knob-drawing circle, expanded dropdown list,
etc.) — keeps the per-variant .py files small + the visual style of
each variant the SOLE differentiator.
"""

from __future__ import annotations

from typing import Any, Dict, Tuple

import numpy as np
from PIL import Image, ImageDraw


def _rgb_tuple(color) -> Tuple[int, int, int]:
    """Convert a vec3 (list/np-array of [0,1] floats) into a 0-255 tuple
    PIL accepts. Idempotent over already-tuple-shaped input."""
    if hasattr(color, "tolist"):
        color = color.tolist()
    return tuple(int(max(0.0, min(1.0, float(c))) * 255) for c in color[:3])


def _scaled_dims(primitive_state: Dict[str, Any]) -> Tuple[int, int]:
    """Compute internal raster (w_px, h_px) from primitive_state's
    geometry fields (matches BoxNode + ScrollBarNode + SliderNode
    convention). Aspect-preserving + capped at screen_resolution."""
    w_world = float(primitive_state.get("screen_width") or 1.0)
    h_world = float(primitive_state.get("screen_height") or 1.0)
    res_max = int(primitive_state.get("screen_resolution") or 256)
    aspect = w_world / max(1e-9, h_world)
    if aspect >= 1.0:
        return res_max, max(1, int(round(res_max / aspect)))
    return max(1, int(round(res_max * aspect))), res_max


def _fraction(primitive_state: Dict[str, Any]) -> float:
    """Compute the [0,1] fractional position of a value across [min,max].
    Used by both scroll-bar and slider variants. Degenerate range (max
    == min) returns 0.5 (centered)."""
    min_v = float(primitive_state.get("min", 0.0))
    max_v = float(primitive_state.get("max", 1.0))
    value = float(primitive_state.get("value", min_v))
    span = max_v - min_v
    if span <= 0.0:
        return 0.5
    f = (value - min_v) / span
    return max(0.0, min(1.0, f))


def _new_image(width: int, height: int, bg) -> Tuple[Image.Image, ImageDraw.ImageDraw]:
    """PIL Image + Draw pair at the given size with bg color."""
    img = Image.new("RGB", (width, height), color=_rgb_tuple(bg))
    return img, ImageDraw.Draw(img)


def _to_float32_array(img: Image.Image) -> np.ndarray:
    """Convert a PIL image to an RGB float32 array in [0, 1]."""
    return np.asarray(img, dtype=np.float32) / 255.0


def _validate_input_shape(input_value: Any, presentation_of: str) -> Dict[str, Any]:
    """Coerce the substrate's ``execute()`` input to ``{primitive_state,
    context}`` form + return the primitive_state dict. Raises
    ``ValueError`` on shape mismatch — the substrate's _execute_renderer
    enforces this at execute-time per the substrate's two-phase
    contract.
    """
    if not isinstance(input_value, dict):
        raise ValueError(
            f"presentation-variant render: input must be a dict "
            f"({{primitive_state, context}}); got {type(input_value).__name__}"
        )
    state = input_value.get("primitive_state")
    if not isinstance(state, dict):
        raise ValueError(
            f"presentation-variant render ({presentation_of}): "
            f"input['primitive_state'] must be a dict; got "
            f"{type(state).__name__}"
        )
    return state
