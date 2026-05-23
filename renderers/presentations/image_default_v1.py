"""image_default_v1 — default raster image variant.

Brief 03 commit 4. Presentation-variant for ImageNode (N-F026 /
SPEC-090). Resolves the ``src`` via PIL + falls back to the
placeholder color when missing/unreadable.

Composes against ``renderers/presentations/_shared.py`` for the
input-validation helper, and against ``node_types/image.py``'s
resolution helper so the missing-source behavior is bit-identical
between the primitive's default emit and this variant. Keeping ONE
resolution function honors mistake #009 (existing-primitive
blindness — extracting and reusing the resolution math rather than
duplicating it inside the variant).
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

from node_types.image import _resolve_image_to_array  # noqa: E402


PRESENTATION_OF = "ImageNode"
DEFAULT_PLACEHOLDER = [0.18, 0.20, 0.26]


def render(input: dict) -> np.ndarray:
    """Render the default image variant to an RGB float32 array.

    Input shape per SPEC-090's presentation-spec contract:
        ``{primitive_state: <ImageNode state>, context?: dict}``.
    """
    state = _validate_input_shape(input, PRESENTATION_OF)
    width, height = _scaled_dims(state)
    placeholder = state.get("placeholder_color", DEFAULT_PLACEHOLDER)
    placeholder_arr = np.asarray(placeholder, dtype=np.float32)
    preserve = bool(state.get("preserve_aspect", True))
    src = state.get("src") or ""

    return _resolve_image_to_array(
        src=src,
        width=width,
        height=height,
        preserve_aspect=preserve,
        placeholder_color=placeholder_arr,
    )
