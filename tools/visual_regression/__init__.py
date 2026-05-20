"""
Visual regression pipeline — SPEC-080.

Captures the Apeiron Tk workflow GUI, compares it against baseline PNGs
using SSIM, and writes failure artifacts when the live shell drifts
from what the maintainer last approved.

The pipeline composes with:

- ``tools.gui_test_driver`` (SPEC-081) — drives the shell to a target
  state before each capture.
- ``tools.ready_check`` (SPEC-064) — exposes a ``visual_regression``
  probe that round-trips a synthetic capture-and-compare so a future
  session can confirm the pipeline itself still works even before any
  production baseline is registered.

Per the design doc (``notes/designs/spec_080_visual_regression_design_2026_05_20.md``)
this PR ships scaffolding only. Wiring up real baselines for every
2D view is SPEC-069's job; the runner here will pick them up once
they land at ``tests/visual_regression/baselines/<name>.png``.

Public surface:

- :func:`capture.capture_widget` — grab a PIL.Image of a Tk widget's
  bounding box.
- :func:`compare.compare_images` — SSIM-based comparison with a 0.98
  default threshold.
- :func:`runner.run_baseline` — orchestrates capture → compare → write
  failure artifact.
- :class:`manifest.BaselineManifest` — declares the registered
  scenes (name → renderer hook).
"""

from __future__ import annotations

from tools.visual_regression.capture import (
    CaptureError,
    HeadlessCaptureError,
    capture_widget,
)
from tools.visual_regression.compare import (
    CompareResult,
    DEFAULT_SSIM_THRESHOLD,
    compare_images,
)
from tools.visual_regression.manifest import BaselineManifest, BaselineSpec
from tools.visual_regression.runner import (
    RunnerResult,
    baselines_dir,
    failures_dir,
    run_baseline,
)


__all__ = [
    "BaselineManifest",
    "BaselineSpec",
    "CaptureError",
    "CompareResult",
    "DEFAULT_SSIM_THRESHOLD",
    "HeadlessCaptureError",
    "RunnerResult",
    "baselines_dir",
    "capture_widget",
    "compare_images",
    "failures_dir",
    "run_baseline",
]
