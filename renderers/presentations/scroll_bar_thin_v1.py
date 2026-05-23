"""scroll_bar_thin_v1 — hairline-rail raster scroll-bar variant."""

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


PRESENTATION_OF = "ScrollBarNode"
DEFAULT_RAIL = [0.30, 0.32, 0.40]
DEFAULT_ACCENT = [0.80, 0.84, 0.92]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    rail_color = state.get("track_color", DEFAULT_RAIL)
    accent_color = state.get("thumb_color", DEFAULT_ACCENT)
    orientation = state.get("orientation", "vertical")
    fraction = _fraction(state)

    img, draw = _new_image(width, height, [0.04, 0.05, 0.07])
    rail_tuple = _rgb_tuple(rail_color)
    accent_tuple = _rgb_tuple(accent_color)

    if orientation == "horizontal":
        y = height // 2
        draw.line([(0, y), (width - 1, y)], fill=rail_tuple, width=1)
        accent_w = max(4, int(round(width * 0.06)))
        accent_h = max(3, int(round(height * 0.30)))
        max_x = max(0, width - accent_w)
        ax = int(round(fraction * max_x))
        ay = (height - accent_h) // 2
        draw.rectangle([(ax, ay), (ax + accent_w - 1, ay + accent_h - 1)],
                       fill=accent_tuple)
    else:
        x = width // 2
        draw.line([(x, 0), (x, height - 1)], fill=rail_tuple, width=1)
        accent_w = max(3, int(round(width * 0.30)))
        accent_h = max(4, int(round(height * 0.06)))
        ax = (width - accent_w) // 2
        max_y = max(0, height - accent_h)
        ay = int(round(fraction * max_y))
        draw.rectangle([(ax, ay), (ax + accent_w - 1, ay + accent_h - 1)],
                       fill=accent_tuple)

    return _to_float32_array(img)
