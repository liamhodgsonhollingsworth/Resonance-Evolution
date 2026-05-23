"""dropdown_chunky_v1 — open-form chunky dropdown raster variant.

Shows the full option list with the selected option highlighted.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

from engine.screen import _get_font, _truncate

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
DEFAULT_BG = [0.16, 0.18, 0.24]
DEFAULT_TEXT = [0.92, 0.93, 0.88]
DEFAULT_SELECTED_BG = [0.30, 0.35, 0.50]
DEFAULT_SELECTED_TEXT = [1.0, 1.0, 1.0]


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    bg = state.get("background_color", DEFAULT_BG)
    text_color = state.get("text_color", DEFAULT_TEXT)
    options = state.get("options", []) or []
    selected = state.get("selected") or ""

    img, draw = _new_image(width, height, bg)
    text_tuple = _rgb_tuple(text_color)
    sel_bg_tuple = _rgb_tuple(DEFAULT_SELECTED_BG)
    sel_text_tuple = _rgb_tuple(DEFAULT_SELECTED_TEXT)

    n = max(1, len(options))
    row_h = max(8, height // max(1, n))
    font_size = max(8, min(row_h * 2 // 3, 18))
    font = _get_font(font_size)
    margin = max(2, font_size // 4)

    y = 0
    for option in options:
        if not isinstance(option, dict):
            continue
        opt_id = option.get("id", "")
        label = str(option.get("label") or opt_id)
        is_selected = opt_id == selected
        if is_selected:
            draw.rectangle([(0, y), (width - 1, y + row_h - 1)], fill=sel_bg_tuple)
            color = sel_text_tuple
        else:
            color = text_tuple
        label_text = _truncate(label, max(4, width - 2 * margin), font)
        text_y = y + max(0, (row_h - font_size) // 2)
        draw.text((margin, text_y), label_text, fill=color, font=font)
        y += row_h
        if y >= height:
            break

    return _to_float32_array(img)
