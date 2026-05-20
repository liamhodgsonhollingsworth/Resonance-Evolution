"""
Compare two images via SSIM — SPEC-080.

Uses ``skimage.metrics.structural_similarity`` with a default threshold
of 0.98 (per the design doc). SSIM is robust against minor anti-
aliasing jitter and 1-2px font-hinting shifts that pixel-exact diffs
flag spuriously.

Output shape:

- ``score`` in [0, 1] (1.0 == identical).
- ``diff_image`` — the per-pixel similarity map promoted to a
  PIL.Image with the inverse normalised so divergent regions are
  bright. The caller can save this directly as a failure artifact.
- ``regions`` — list of ``(x, y, w, h)`` bounding boxes around
  contiguous diff-heavy areas. Populated only when the score falls
  below the threshold; empty otherwise.

The signature accepts side-by-side PIL.Image instances. The images
are coerced to identical mode + size before SSIM runs — divergent
sizes auto-fail (score 0, regions covering the whole baseline) since
SSIM is undefined on different-shape images and we don't want to
silently resize and hide a real layout shift.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, List, Tuple

import numpy as np


DEFAULT_SSIM_THRESHOLD: float = 0.98


@dataclass
class CompareResult:
    """The verdict from :func:`compare_images`.

    Attributes:
        score: SSIM score in [0, 1]; 1.0 == identical.
        passed: Whether ``score`` cleared the threshold the comparison
            ran against.
        threshold: The threshold used (echoed for traceability).
        diff_image: A PIL.Image visualising the per-pixel divergence;
            bright regions = high divergence.
        regions: Bounding boxes (x, y, w, h) of diff-heavy areas; empty
            on pass.
        summary: One-line human-readable summary suitable for an
            assertion message.
    """

    score: float
    passed: bool
    threshold: float
    diff_image: Any
    regions: List[Tuple[int, int, int, int]] = field(default_factory=list)
    summary: str = ""


def _to_grayscale_array(img: Any) -> np.ndarray:
    """Convert a PIL.Image to a float32 grayscale numpy array in [0, 1].

    SSIM operates on grayscale by default in the design doc's
    threshold (0.98) — colour-channel SSIM produces lower scores under
    the same perceptual drift and would require recalibrating the
    threshold. Sticking with grayscale matches the design doc.
    """
    if hasattr(img, "convert"):
        gray = img.convert("L")
    else:
        gray = img
    arr = np.asarray(gray, dtype=np.float32) / 255.0
    return arr


def _bounding_boxes_of_diff(diff_map: np.ndarray, threshold_norm: float = 0.5
                            ) -> List[Tuple[int, int, int, int]]:
    """Find bounding boxes of contiguous diff-heavy areas.

    The diff-map is in [0, 1] (1 == most different). We threshold at
    ``threshold_norm`` and walk a tiny flood-fill to discover connected
    components, returning the bounding box of each.

    Implementation note: scipy.ndimage.label is available (scipy is
    already an Apeiron transitive dep via scikit-image), but pulling
    it in for this would inflate the dep surface. A pure-numpy
    iterative flood-fill is short and stays self-contained.
    """
    if diff_map.size == 0:
        return []
    mask = diff_map >= threshold_norm
    if not mask.any():
        return []

    visited = np.zeros_like(mask, dtype=bool)
    boxes: List[Tuple[int, int, int, int]] = []
    h, w = mask.shape

    # Use scipy if it's already importable; otherwise pure numpy.
    try:
        from scipy.ndimage import label, find_objects
        labeled, n = label(mask)
        slices = find_objects(labeled)
        for sl in slices:
            if sl is None:
                continue
            ys, xs = sl
            boxes.append(
                (int(xs.start), int(ys.start),
                 int(xs.stop - xs.start), int(ys.stop - ys.start))
            )
        return boxes
    except Exception:
        pass

    # Pure-numpy fallback — iterative BFS.
    for y in range(h):
        for x in range(w):
            if mask[y, x] and not visited[y, x]:
                # BFS this component.
                stack = [(y, x)]
                ymin, ymax = y, y
                xmin, xmax = x, x
                while stack:
                    cy, cx = stack.pop()
                    if cy < 0 or cy >= h or cx < 0 or cx >= w:
                        continue
                    if visited[cy, cx] or not mask[cy, cx]:
                        continue
                    visited[cy, cx] = True
                    ymin = min(ymin, cy)
                    ymax = max(ymax, cy)
                    xmin = min(xmin, cx)
                    xmax = max(xmax, cx)
                    stack.extend([(cy + 1, cx), (cy - 1, cx),
                                  (cy, cx + 1), (cy, cx - 1)])
                boxes.append(
                    (xmin, ymin, xmax - xmin + 1, ymax - ymin + 1)
                )
    return boxes


def _coerce_same_shape(a: Any, b: Any) -> Tuple[Any, Any, bool]:
    """Return (a', b', shapes_matched). If the source images have
    different sizes or modes, this returns the originals plus False
    so the caller can fail loudly rather than silently resize.
    """
    if hasattr(a, "size") and hasattr(b, "size"):
        if a.size != b.size:
            return a, b, False
    if hasattr(a, "mode") and hasattr(b, "mode") and a.mode != b.mode:
        # Try converting both to grayscale for comparison purposes;
        # don't return them as the originals.
        return a.convert("L") if hasattr(a, "convert") else a, \
               b.convert("L") if hasattr(b, "convert") else b, True
    return a, b, True


def compare_images(
    baseline: Any,
    fresh: Any,
    threshold: float = DEFAULT_SSIM_THRESHOLD,
) -> CompareResult:
    """Compute SSIM between two PIL.Image instances.

    Args:
        baseline: The reference image (loaded from
            ``tests/visual_regression/baselines/<name>.png``).
        fresh: The newly-captured image.
        threshold: SSIM score below which ``passed`` flips to False.
            Default 0.98 matches the design doc.

    Returns:
        A :class:`CompareResult`. ``regions`` is populated when the
        score falls below threshold.

    The comparison fails with ``score=0.0`` if the two images don't
    share dimensions; SSIM is undefined across shapes and silent
    resizing would mask layout drift.
    """
    if baseline is None or fresh is None:
        raise ValueError("compare_images requires two non-None images")

    # Shape match check.
    baseline_co, fresh_co, shapes_ok = _coerce_same_shape(baseline, fresh)
    if not shapes_ok:
        # Build a synthetic diff image — same size as baseline, all white.
        from PIL import Image
        b_size = getattr(baseline, "size", (0, 0))
        diff_img = Image.new("L", b_size, color=255)
        full_box = (0, 0, b_size[0] if b_size[0] > 0 else 1,
                    b_size[1] if b_size[1] > 0 else 1)
        return CompareResult(
            score=0.0,
            passed=False,
            threshold=threshold,
            diff_image=diff_img,
            regions=[full_box],
            summary=(
                f"size mismatch: baseline={getattr(baseline, 'size', '?')} "
                f"fresh={getattr(fresh, 'size', '?')} -> automatic fail"
            ),
        )

    a = _to_grayscale_array(baseline_co)
    b = _to_grayscale_array(fresh_co)

    from skimage.metrics import structural_similarity

    # ``full=True`` returns the per-pixel SSIM map. We need it for the
    # diff image + region detection.
    score, ssim_map = structural_similarity(
        a, b, data_range=1.0, full=True,
    )
    # ssim_map is in [-1, 1]; convert to a "divergence" map in [0, 1].
    # 1.0 in ssim_map (perfect match) -> 0.0 divergence; lower scores
    # -> higher divergence.
    divergence = np.clip(1.0 - ssim_map, 0.0, 1.0)

    passed = bool(score >= threshold)

    regions: List[Tuple[int, int, int, int]] = []
    if not passed:
        regions = _bounding_boxes_of_diff(divergence, threshold_norm=0.1)

    # Promote the divergence map to a PIL.Image (uint8, grayscale).
    from PIL import Image
    diff_arr_u8 = (divergence * 255.0).astype(np.uint8)
    diff_image = Image.fromarray(diff_arr_u8, mode="L")

    summary = (
        f"SSIM={score:.4f} (threshold {threshold:.2f}): "
        f"{'PASS' if passed else 'FAIL'}"
    )
    if regions:
        summary += f"; {len(regions)} diff region(s)"

    return CompareResult(
        score=float(score),
        passed=passed,
        threshold=threshold,
        diff_image=diff_image,
        regions=regions,
        summary=summary,
    )
