"""dropdown_radial_v1 — radial dropdown raster variant.

Options arranged at equal angles around a center; selected option drawn
as a larger dot.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

_PRESENTATIONS_DIR = Path(__file__).resolve().parent
if str(_PRESENTATIONS_DIR) not in sys.path:
    sys.path.insert(0, str(_PRESENTATIONS_DIR))

from _shared import (  # noqa: E402
    _new_image,
    _rgb_tuple,
    _scaled_dims,
    _to_float32_array,
    _validate_input_shape,
)


PRESENTATION_OF = "DropdownNode"
DEFAULT_BG = [0.06, 0.07, 0.10]
DEFAULT_DOT = [0.55, 0.62, 0.78]
DEFAULT_SELECTED_DOT = [0.95, 0.97, 1.00]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    bg = state.get("background_color", DEFAULT_BG)
    options = state.get("options", []) or []
    selected = state.get("selected") or ""

    img, draw = _new_image(width, height, bg)
    dot_tuple = _rgb_tuple(DEFAULT_DOT)
    sel_tuple = _rgb_tuple(DEFAULT_SELECTED_DOT)

    cx = width // 2
    cy = height // 2
    radius = max(8, min(width, height) // 2 - 6)
    n = len([o for o in options if isinstance(o, dict)])
    if n == 0:
        return _to_float32_array(img)

    dot_r = max(3, radius // 6)
    for i, option in enumerate([o for o in options if isinstance(o, dict)]):
        angle = (2 * math.pi * i / n) - math.pi / 2  # start at top
        x = cx + int(round(radius * math.cos(angle)))
        y = cy + int(round(radius * math.sin(angle)))
        opt_id = option.get("id", "")
        is_selected = opt_id == selected
        r = dot_r * 2 if is_selected else dot_r
        color = sel_tuple if is_selected else dot_tuple
        draw.ellipse([(x - r, y - r), (x + r, y + r)], fill=color)

    # Center indicator: small ring at center connecting visually to the
    # selected option.
    center_r = max(2, dot_r // 2)
    draw.ellipse([(cx - center_r, cy - center_r),
                  (cx + center_r, cy + center_r)], outline=sel_tuple, width=1)

    return _to_float32_array(img)
