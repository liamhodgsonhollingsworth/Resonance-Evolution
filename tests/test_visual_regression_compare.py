"""
Tests for SPEC-080 visual-regression compare surface.

Covers SSIM scoring against synthetic baselines:

- Identical images return score 1.0 and passed=True.
- Light noise stays above the 0.98 threshold (the design doc's
  noise-tolerance promise).
- Substantial diffs fall below threshold and populate the regions
  list with bounding boxes.
- Size mismatches auto-fail without silent resizing.
"""

from __future__ import annotations

import numpy as np
import pytest
from PIL import Image

from tools.visual_regression.compare import (
    DEFAULT_SSIM_THRESHOLD,
    compare_images,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_image(size: tuple, value: int = 128, mode: str = "RGB") -> Image.Image:
    """Construct a solid-colour image of *size* at the given grayscale
    intensity (broadcast across RGB)."""
    if mode == "RGB":
        return Image.new("RGB", size, color=(value, value, value))
    return Image.new(mode, size, color=value)


def _make_image_with_glyph(
    size: tuple, base: int = 128, glyph_x: int = 20, glyph_y: int = 10
) -> Image.Image:
    """Construct an image with a small dark 'glyph' at the given
    position. Used to simulate font-hinting jitter — Tk renders the
    same text at slightly different sub-pixel offsets across builds,
    which empirically looks like a 1-2px shift of small regions, NOT
    pixel-wide random noise."""
    arr = np.full((size[1], size[0], 3), base, dtype=np.uint8)
    # 5x5 dark patch at (glyph_x, glyph_y) — the design doc's
    # "anti-aliasing jitter" scenario.
    arr[glyph_y:glyph_y + 5, glyph_x:glyph_x + 5, :] = 0
    return Image.fromarray(arr, mode="RGB")


def _make_split_image(
    size: tuple, left_value: int = 50, right_value: int = 200
) -> Image.Image:
    """Construct an image with a hard divide down the middle — used to
    produce a real diff against a uniform baseline."""
    arr = np.full((size[1], size[0], 3), left_value, dtype=np.uint8)
    arr[:, size[0] // 2:, :] = right_value
    return Image.fromarray(arr, mode="RGB")


# ---------------------------------------------------------------------------
# Happy path.
# ---------------------------------------------------------------------------


def test_identical_images_score_one():
    img = _make_image((64, 64), value=128)
    result = compare_images(img, img.copy())
    assert result.score == pytest.approx(1.0, abs=1e-6)
    assert result.passed is True
    assert result.regions == []
    assert result.threshold == DEFAULT_SSIM_THRESHOLD


def test_identical_images_diff_image_is_dark():
    """Identical images -> divergence map is all zero -> diff PNG is
    fully black."""
    img = _make_image((32, 32))
    result = compare_images(img, img.copy())
    diff_arr = np.asarray(result.diff_image)
    assert diff_arr.max() == 0


def test_tiny_noise_stays_above_threshold():
    """Per design: SSIM 0.98 tolerates anti-aliasing jitter + 1-2px
    font-hinting shifts. Realistic Tk jitter looks like a glyph
    rendered one pixel over, not whole-image random noise — small
    localised diffs preserve high SSIM."""
    # Same image with one "glyph" position shifted by 1 pixel.
    a = _make_image_with_glyph((128, 128), base=128, glyph_x=20, glyph_y=10)
    b = _make_image_with_glyph((128, 128), base=128, glyph_x=21, glyph_y=10)
    result = compare_images(a, b)
    assert result.score > DEFAULT_SSIM_THRESHOLD, (
        f"SSIM {result.score:.4f} below {DEFAULT_SSIM_THRESHOLD} "
        f"on a 1px glyph shift (anti-aliasing jitter analog)"
    )
    assert result.passed is True
    assert result.regions == []


def test_substantial_diff_fails_and_populates_regions():
    """A hard left-vs-right split produces SSIM well below the
    threshold and the divergence map yields at least one bbox."""
    a = _make_image((64, 64), value=128)
    b = _make_split_image((64, 64), left_value=128, right_value=10)
    result = compare_images(a, b)
    assert result.score < DEFAULT_SSIM_THRESHOLD
    assert result.passed is False
    assert len(result.regions) >= 1
    # Each region is a (x, y, w, h) tuple.
    for box in result.regions:
        assert len(box) == 4
        x, y, w, h = box
        assert w > 0 and h > 0


def test_lower_threshold_can_flip_verdict():
    """A custom looser threshold can salvage a borderline case."""
    a = _make_image((64, 64), value=128)
    # Mostly-similar image (one quadrant shifted only).
    arr = np.full((64, 64, 3), 128, dtype=np.uint8)
    arr[0:8, 0:8] = 40
    b = Image.fromarray(arr, mode="RGB")
    strict = compare_images(a, b, threshold=0.99)
    loose = compare_images(a, b, threshold=0.5)
    assert strict.score == loose.score
    assert strict.passed is False
    assert loose.passed is True
    assert strict.threshold == 0.99
    assert loose.threshold == 0.5


# ---------------------------------------------------------------------------
# Edge cases.
# ---------------------------------------------------------------------------


def test_size_mismatch_auto_fails():
    """SSIM is undefined across shapes — comparison must auto-fail
    without resizing."""
    a = _make_image((64, 64))
    b = _make_image((32, 32))
    result = compare_images(a, b)
    assert result.passed is False
    assert result.score == 0.0
    assert "size mismatch" in result.summary
    assert len(result.regions) == 1


def test_none_inputs_raise_value_error():
    with pytest.raises(ValueError):
        compare_images(None, _make_image((4, 4)))
    with pytest.raises(ValueError):
        compare_images(_make_image((4, 4)), None)


def test_summary_includes_score_and_threshold():
    img = _make_image((16, 16))
    result = compare_images(img, img.copy(), threshold=0.95)
    assert "SSIM=" in result.summary
    assert "0.95" in result.summary
    assert "PASS" in result.summary


def test_compare_handles_grayscale_input():
    """Grayscale-mode PIL.Image inputs flow through correctly."""
    a = Image.new("L", (32, 32), color=128)
    b = Image.new("L", (32, 32), color=128)
    result = compare_images(a, b)
    assert result.score == pytest.approx(1.0, abs=1e-6)
    assert result.passed is True
