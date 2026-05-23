"""Tests for image_default_v1 + video_default_v1 visual variants.

Brief 03 commit 4. Covers the presentation-spec contract for the
two content primitives shipped this commit:

- Render through the variant's render(input) function with primitive_
  state-shaped input.
- Output is an RGB float32 array of (height, width, 3) honoring the
  primitive's geometry fields.
- Variant render output matches the primitive's default emit (the
  bit-identical-via-shared-helper invariant from mistake #009 — both
  paths use the same _resolve_image_to_array / _resolve_video_first_
  frame extractor).
- Variants raise ValueError on shape-mismatched input (the
  presentation-spec contract enforces {primitive_state, context?}).

Per the per-module plan Scenario 2 (*"Swap visual variant; functional
behavior unchanged"*).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(APEIRON_ROOT))
sys.path.insert(0, str(APEIRON_ROOT / "renderers" / "presentations"))


@pytest.fixture
def temp_png(tmp_path):
    arr = np.zeros((24, 24, 3), dtype=np.uint8)
    arr[..., 1] = 200  # mostly green
    img = Image.fromarray(arr, mode="RGB")
    path = tmp_path / "image.png"
    img.save(path)
    return path


# --------------------------------------------------------------------------
# image_default_v1
# --------------------------------------------------------------------------


def test_image_default_v1_renders_empty_src():
    from image_default_v1 import render
    res = render({
        "primitive_state": {
            "src": "",
            "preserve_aspect": True,
            "screen_width": 2.0,
            "screen_height": 2.0,
            "screen_resolution": 32,
            "placeholder_color": [0.5, 0.5, 0.5],
        }
    })
    assert res.shape == (32, 32, 3)
    assert res.dtype == np.float32
    # Placeholder uniform: every pixel near the placeholder color.
    np.testing.assert_allclose(res.mean(axis=(0, 1)), [0.5, 0.5, 0.5], atol=0.05)


def test_image_default_v1_renders_file_src(temp_png):
    from image_default_v1 import render
    res = render({
        "primitive_state": {
            "src": str(temp_png),
            "preserve_aspect": True,
            "screen_width": 2.0,
            "screen_height": 2.0,
            "screen_resolution": 64,
        }
    })
    assert res.shape == (64, 64, 3)
    # Green channel dominant since the source is mostly green.
    assert res.mean(axis=(0, 1))[1] > res.mean(axis=(0, 1))[0]


def test_image_default_v1_rejects_bad_input_shape():
    from image_default_v1 import render
    with pytest.raises(ValueError, match="primitive_state"):
        render({"bad": "shape"})
    with pytest.raises(ValueError, match="primitive_state"):
        render("not a dict")


def test_image_default_v1_matches_primitive_emit(temp_png):
    """The variant + the primitive's default emit produce equivalent
    output (the mistake #009 invariant — extract-and-reuse)."""
    from node_types.image import _resolve_image_to_array
    placeholder = np.asarray([0.18, 0.20, 0.26], dtype=np.float32)
    direct = _resolve_image_to_array(
        src=str(temp_png),
        width=32,
        height=32,
        preserve_aspect=True,
        placeholder_color=placeholder,
    )
    from image_default_v1 import render
    via_variant = render({
        "primitive_state": {
            "src": str(temp_png),
            "preserve_aspect": True,
            "screen_width": 2.0,
            "screen_height": 2.0,
            "screen_resolution": 32,
            "placeholder_color": [0.18, 0.20, 0.26],
        }
    })
    # Both must be bit-identical (the variant just delegates to the
    # primitive's resolver).
    np.testing.assert_array_equal(direct, via_variant)


# --------------------------------------------------------------------------
# video_default_v1
# --------------------------------------------------------------------------


def test_video_default_v1_renders_empty_src():
    from video_default_v1 import render
    res = render({
        "primitive_state": {
            "src": "",
            "alt_text": "alt",
            "screen_width": 2.0,
            "screen_height": 1.0,
            "screen_resolution": 32,
            "placeholder_color": [0.05, 0.05, 0.05],
            "text_color": [0.9, 0.9, 0.9],
        }
    })
    assert res.shape == (16, 32, 3)
    assert res.dtype == np.float32


def test_video_default_v1_rejects_bad_input_shape():
    from video_default_v1 import render
    with pytest.raises(ValueError, match="primitive_state"):
        render({"no_primitive_state": True})


def test_video_default_v1_matches_primitive_emit():
    """Same extract-and-reuse invariant as the image variant."""
    from node_types.video import _resolve_video_first_frame
    placeholder = np.asarray([0.05, 0.05, 0.05], dtype=np.float32)
    text_color = np.asarray([0.9, 0.9, 0.9], dtype=np.float32)
    direct = _resolve_video_first_frame(
        src="",
        alt_text="alt",
        width=32,
        height=16,
        placeholder_color=placeholder,
        text_color=text_color,
    )
    from video_default_v1 import render
    via_variant = render({
        "primitive_state": {
            "src": "",
            "alt_text": "alt",
            "screen_width": 2.0,
            "screen_height": 1.0,
            "screen_resolution": 32,
            "placeholder_color": [0.05, 0.05, 0.05],
            "text_color": [0.9, 0.9, 0.9],
        }
    })
    np.testing.assert_array_equal(direct, via_variant)


# --------------------------------------------------------------------------
# Substrate execute() dispatch via _execute_renderer
# --------------------------------------------------------------------------


def test_image_variant_dispatches_via_substrate_execute(temp_png, tmp_path,
                                                         monkeypatch):
    """The variant's .md manifest + .py implementation compose against
    the substrate's _execute_renderer dispatch (SPEC-082 contract).

    The substrate enforces a python-callable path allowlist; we point
    SUBSTRATE_PROJECT_ROOT at the Apeiron repo + allowlist
    renderers/presentations/ so the variant resolves.
    """
    # Locate Alethea-cc/substrate.
    substrate_dir = APEIRON_ROOT.parent / "Alethea" / "Alethea-cc" / "substrate"
    if not substrate_dir.exists():
        pytest.skip(f"Alethea-cc substrate not present at {substrate_dir}")
    if str(substrate_dir) not in sys.path:
        sys.path.insert(0, str(substrate_dir))
    monkeypatch.setenv("ALETHEA_AUTO_NOTION_SYNC", "0")
    monkeypatch.setenv("SUBSTRATE_PROJECT_ROOT", str(APEIRON_ROOT))
    monkeypatch.setenv("SUBSTRATE_ALLOWED_PATH_PREFIXES",
                       "renderers/presentations/")

    from evaluator import read_node  # type: ignore
    from primitives import execute  # type: ignore

    variant_md = APEIRON_ROOT / "renderers" / "presentations" / "image_default_v1.md"
    node = read_node(variant_md)
    res = execute(node, input={
        "primitive_state": {
            "src": str(temp_png),
            "preserve_aspect": True,
            "screen_width": 1.0,
            "screen_height": 1.0,
            "screen_resolution": 16,
            "placeholder_color": [0.5, 0.5, 0.5],
        }
    })
    assert isinstance(res, np.ndarray)
    assert res.shape == (16, 16, 3)
