"""slider_knob_v1 — knob raster slider variant.

Functional state identical to the rectangular-thumb variants; renders a
circular thumb on a thin track instead.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

_PRESENTATIONS_DIR = Path(__file__).resolve().parent
if str(_PRESENTATIONS_DIR) not in sys.path:
    sys.path.insert(0, str(_PRESENTATIONS_DIR))

from _shared import (  # noqa: E402
    _fraction,
    _new_image,
    _rgb_tuple,
    _scaled_dims,
    _to_float32_array,
    _validate_input_shape,
)


PRESENTATION_OF = "SliderNode"
DEFAULT_TRACK = [0.18, 0.20, 0.26]
DEFAULT_KNOB = [0.85, 0.90, 0.98]
DEFAULT_KNOB_OUTLINE = [0.50, 0.55, 0.65]
DEFAULT_BG = [0.04, 0.05, 0.07]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    track_color = state.get("track_color", DEFAULT_TRACK)
    knob_color = state.get("thumb_color", DEFAULT_KNOB)
    orientation = state.get("orientation", "horizontal")
    fraction = _fraction(state)

    img, draw = _new_image(width, height, DEFAULT_BG)
    track_tuple = _rgb_tuple(track_color)
    knob_tuple = _rgb_tuple(knob_color)
    outline_tuple = _rgb_tuple(DEFAULT_KNOB_OUTLINE)

    margin = max(6, min(width, height) // 8)

    if orientation == "vertical":
        x = width // 2
        draw.line([(x, margin), (x, height - margin)], fill=track_tuple, width=2)
        knob_radius = max(4, min(width, height) // 5)
        max_y = max(0, (height - 2 * margin) - 2 * knob_radius)
        ky = margin + knob_radius + int(round((1.0 - fraction) * max_y))
        kx = x
    else:
        y = height // 2
        draw.line([(margin, y), (width - margin, y)], fill=track_tuple, width=2)
        knob_radius = max(4, min(width, height) // 5)
        max_x = max(0, (width - 2 * margin) - 2 * knob_radius)
        kx = margin + knob_radius + int(round(fraction * max_x))
        ky = y

    bbox = [(kx - knob_radius, ky - knob_radius),
            (kx + knob_radius, ky + knob_radius)]
    draw.ellipse(bbox, fill=knob_tuple, outline=outline_tuple, width=2)

    return _to_float32_array(img)
