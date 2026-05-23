"""slider_minimal_v1 — minimal raster slider variant."""

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
DEFAULT_THUMB = [0.62, 0.70, 0.82]
DEFAULT_BG = [0.05, 0.06, 0.08]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    track_color = state.get("track_color", DEFAULT_TRACK)
    thumb_color = state.get("thumb_color", DEFAULT_THUMB)
    orientation = state.get("orientation", "horizontal")
    fraction = _fraction(state)

    img, draw = _new_image(width, height, DEFAULT_BG)
    track_tuple = _rgb_tuple(track_color)
    thumb_tuple = _rgb_tuple(thumb_color)

    if orientation == "vertical":
        track_w = max(2, int(round(width * 0.12)))
        track_x = (width - track_w) // 2
        margin = max(4, height // 16)
        draw.rectangle(
            [(track_x, margin), (track_x + track_w - 1, height - margin)],
            fill=track_tuple,
        )
        thumb_w = max(4, int(round(width * 0.70)))
        thumb_h = max(3, int(round(height * 0.07)))
        thumb_x = (width - thumb_w) // 2
        max_thumb_y = max(0, (height - 2 * margin) - thumb_h)
        thumb_y = margin + int(round((1.0 - fraction) * max_thumb_y))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )
    else:
        track_h = max(2, int(round(height * 0.12)))
        track_y = (height - track_h) // 2
        margin = max(4, width // 16)
        draw.rectangle(
            [(margin, track_y), (width - margin, track_y + track_h - 1)],
            fill=track_tuple,
        )
        thumb_w = max(3, int(round(width * 0.07)))
        thumb_h = max(4, int(round(height * 0.70)))
        thumb_y = (height - thumb_h) // 2
        max_thumb_x = max(0, (width - 2 * margin) - thumb_w)
        thumb_x = margin + int(round(fraction * max_thumb_x))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )

    return _to_float32_array(img)
