"""scroll_bar_chunky_v1 — chunky raster scroll-bar variant.

Brief 03 commit 3. Same functional state as the minimal variant; the
visual differs: full-bleed track + larger thumb + outlined border.
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


PRESENTATION_OF = "ScrollBarNode"
DEFAULT_TRACK = [0.25, 0.27, 0.34]
DEFAULT_THUMB = [0.65, 0.72, 0.85]
DEFAULT_OUTLINE = [0.90, 0.92, 0.95]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    track_color = state.get("track_color", DEFAULT_TRACK)
    thumb_color = state.get("thumb_color", DEFAULT_THUMB)
    orientation = state.get("orientation", "vertical")
    fraction = _fraction(state)

    img, draw = _new_image(width, height, track_color)
    thumb_tuple = _rgb_tuple(thumb_color)
    outline_tuple = _rgb_tuple(DEFAULT_OUTLINE)

    # Chunky thumb — ~40% of the long axis with outline for tactile contrast.
    if orientation == "horizontal":
        thumb_w = max(8, int(round(width * 0.40)))
        thumb_h = max(8, int(round(height * 0.90)))
        thumb_y = (height - thumb_h) // 2
        max_thumb_x = max(0, width - thumb_w)
        thumb_x = int(round(fraction * max_thumb_x))
    else:
        thumb_w = max(8, int(round(width * 0.90)))
        thumb_h = max(8, int(round(height * 0.40)))
        thumb_x = (width - thumb_w) // 2
        max_thumb_y = max(0, height - thumb_h)
        thumb_y = int(round(fraction * max_thumb_y))

    draw.rectangle(
        [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
        fill=thumb_tuple,
        outline=outline_tuple,
        width=2,
    )

    return _to_float32_array(img)
