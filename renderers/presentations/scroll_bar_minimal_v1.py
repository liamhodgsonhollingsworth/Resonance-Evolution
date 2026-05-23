"""scroll_bar_minimal_v1 — minimal raster scroll-bar variant.

Brief 03 commit 3. Presentation-variant for ScrollBarNode (N-F023 /
SPEC-090). Renders a thin centered track + small thumb at the value's
fractional position.

Composes against ``renderers/presentations/_shared.py`` for the
input-validation + frac + image-construction helpers; the visual
choices (thin track, small thumb) ARE this variant's identity.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

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
DEFAULT_TRACK = [0.20, 0.22, 0.28]
DEFAULT_THUMB = [0.55, 0.60, 0.70]


def render(input: dict) -> np.ndarray:
    """Render the minimal-style scroll-bar to an RGB float32 array.

    Input shape per SPEC-090's presentation-spec contract:
        ``{primitive_state: <ScrollBarNode state>, context?: dict}``.
    """
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    track_color = state.get("track_color", DEFAULT_TRACK)
    thumb_color = state.get("thumb_color", DEFAULT_THUMB)
    orientation = state.get("orientation", "vertical")
    fraction = _fraction(state)

    img, draw = _new_image(width, height, [0.06, 0.07, 0.10])
    track_tuple = _rgb_tuple(track_color)
    thumb_tuple = _rgb_tuple(thumb_color)

    if orientation == "horizontal":
        # Thin centered horizontal track + small vertical thumb.
        track_h = max(2, int(round(height * 0.18)))
        track_y = (height - track_h) // 2
        draw.rectangle([(0, track_y), (width - 1, track_y + track_h - 1)],
                       fill=track_tuple)
        thumb_w = max(2, int(round(width * 0.12)))
        thumb_h = max(4, int(round(height * 0.65)))
        thumb_y = (height - thumb_h) // 2
        max_thumb_x = max(0, width - thumb_w)
        thumb_x = int(round(fraction * max_thumb_x))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )
    else:
        # Vertical: thin centered vertical track + small horizontal thumb.
        track_w = max(2, int(round(width * 0.18)))
        track_x = (width - track_w) // 2
        draw.rectangle([(track_x, 0), (track_x + track_w - 1, height - 1)],
                       fill=track_tuple)
        thumb_w = max(4, int(round(width * 0.65)))
        thumb_h = max(2, int(round(height * 0.12)))
        thumb_x = (width - thumb_w) // 2
        max_thumb_y = max(0, height - thumb_h)
        thumb_y = int(round(fraction * max_thumb_y))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )

    return _to_float32_array(img)
