"""video_default_v1 — default raster video variant.

Brief 03 commit 4. Presentation-variant for VideoNode (N-F026 /
SPEC-090). Delegates to the primitive's first-frame resolver so the
missing-source / missing-decoder behavior is bit-identical between
the default emit and this variant (mistake #009 discipline —
extract-and-reuse).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import numpy as np

_PRESENTATIONS_DIR = Path(__file__).resolve().parent
if str(_PRESENTATIONS_DIR) not in sys.path:
    sys.path.insert(0, str(_PRESENTATIONS_DIR))

_REPO_ROOT = _PRESENTATIONS_DIR.parent.parent  # Apeiron/
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from _shared import (  # noqa: E402
    _scaled_dims,
    _validate_input_shape,
)

from node_types.video import _resolve_video_first_frame  # noqa: E402


PRESENTATION_OF = "VideoNode"
DEFAULT_PLACEHOLDER = [0.10, 0.10, 0.13]
DEFAULT_TEXT_COLOR = [0.78, 0.80, 0.82]


def render(input: dict) -> np.ndarray:
    """Render the default video variant to an RGB float32 array.

    Input shape per SPEC-090's presentation-spec contract:
        ``{primitive_state: <VideoNode state>, context?: dict}``.
    """
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    placeholder = state.get("placeholder_color", DEFAULT_PLACEHOLDER)
    text_color = state.get("text_color", DEFAULT_TEXT_COLOR)
    placeholder_arr = np.asarray(placeholder, dtype=np.float32)
    text_color_arr = np.asarray(text_color, dtype=np.float32)
    src = state.get("src") or ""
    alt_text = state.get("alt_text") or ""

    return _resolve_video_first_frame(
        src=src,
        alt_text=alt_text,
        width=width,
        height=height,
        placeholder_color=placeholder_arr,
        text_color=text_color_arr,
    )
