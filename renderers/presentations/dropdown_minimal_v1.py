"""dropdown_minimal_v1 — minimal closed-form dropdown raster variant."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import ImageDraw

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
DEFAULT_CHEVRON = [0.62, 0.70, 0.82]


def _selected_label(state: dict) -> str:
    selected = state.get("selected") or ""
    for option in state.get("options", []) or []:
        if isinstance(option, dict) and option.get("id") == selected:
            return str(option.get("label") or selected)
    return "(no selection)"


def render(input: dict) -> np.ndarray:
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    bg = state.get("background_color", DEFAULT_BG)
    text_color = state.get("text_color", DEFAULT_TEXT)
    chevron_color = state.get("chevron_color", DEFAULT_CHEVRON)
    label = _selected_label(state)

    img, draw = _new_image(width, height, bg)
    text_tuple = _rgb_tuple(text_color)
    chevron_tuple = _rgb_tuple(chevron_color)

    font_size = max(12, height // 3)
    font = _get_font(font_size)
    margin = max(4, font_size // 3)
    chevron_w = max(8, height // 2)
    label_max_w = max(8, width - 3 * margin - chevron_w)
    label_text = _truncate(label, label_max_w, font) if label else ""

    if label_text:
        text_y = max(0, (height - font_size) // 2)
        draw.text((margin, text_y), label_text, fill=text_tuple, font=font)

    chev_cx = width - margin - chevron_w // 2
    chev_cy = height // 2
    chev_half_w = chevron_w // 2
    chev_half_h = max(3, chevron_w // 3)
    draw.polygon(
        [
            (chev_cx - chev_half_w, chev_cy - chev_half_h),
            (chev_cx + chev_half_w, chev_cy - chev_half_h),
            (chev_cx, chev_cy + chev_half_h),
        ],
        fill=chevron_tuple,
    )

    return _to_float32_array(img)
