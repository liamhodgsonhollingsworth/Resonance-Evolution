"""
Tests for SPEC-080 visual-regression runner.

End-to-end orchestration: fixture baseline + matching capture -> pass;
fixture baseline + drifted capture -> fail + failure artifact written
to the failures dir.

The renderer hook in production returns a Tk widget; in these tests
it returns a stub widget and the capture grabber is swapped so no
display is needed.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from tools.visual_regression import capture
from tools.visual_regression.manifest import BaselineManifest, BaselineSpec
from tools.visual_regression.runner import (
    RunnerResult,
    baselines_dir,
    failures_dir,
    run_baseline,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


class _StubWidget:
    """A Tk-shaped stub widget for the runner tests."""

    def __init__(self, w: int = 32, h: int = 32) -> None:
        self.w = w
        self.h = h

    def winfo_rootx(self): return 0
    def winfo_rooty(self): return 0
    def winfo_width(self): return self.w
    def winfo_height(self): return self.h
    def update_idletasks(self): pass
    def update(self): pass


def _solid_image(size: tuple, color: int = 128) -> Image.Image:
    return Image.new("RGB", size, color=(color, color, color))


def _split_image(size: tuple) -> Image.Image:
    arr = np.full((size[1], size[0], 3), 200, dtype=np.uint8)
    arr[:, : size[0] // 2, :] = 20
    return Image.fromarray(arr, mode="RGB")


@pytest.fixture(autouse=True)
def _patch_grab(monkeypatch):
    """Default: the grab returns a solid 32x32 image at value 128.

    Tests override this per-case by replacing ``capture._GRAB_HOOK``
    directly inside the test body.
    """
    monkeypatch.setattr(capture, "_PUMP_DELAY_S", 0.0)
    monkeypatch.setattr(
        capture, "_GRAB_HOOK",
        lambda bbox: _solid_image((bbox[2] - bbox[0], bbox[3] - bbox[1])),
    )
    yield


@pytest.fixture
def tmp_root(tmp_path):
    """Returns a tmp path that mimics the Apeiron repo root for
    baselines/failures artifacts."""
    (tmp_path / "tests" / "visual_regression").mkdir(parents=True)
    return tmp_path


# ---------------------------------------------------------------------------
# Pass / fail end-to-end.
# ---------------------------------------------------------------------------


def test_baselines_dir_creates_path(tmp_root):
    d = baselines_dir(tmp_root)
    assert d.exists()
    assert d == tmp_root / "tests" / "visual_regression" / "baselines"


def test_failures_dir_creates_path(tmp_root):
    d = failures_dir(tmp_root)
    assert d.exists()
    assert d == tmp_root / "tests" / "visual_regression" / "failures"


def test_run_baseline_matching_capture_passes(tmp_root):
    """Fixture baseline + grab returning the same image -> pass."""
    name = "scene_pass"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(name=name, renderer=lambda: _StubWidget())
    )
    # Establish the baseline file: the grabber returns 128-gray; the
    # baseline matches.
    baseline_path = baselines_dir(tmp_root) / f"{name}.png"
    _solid_image((32, 32), 128).save(baseline_path)

    result = run_baseline(name, manifest=manifest, root=tmp_root)

    assert result.passed is True
    assert result.status == "pass"
    assert result.compare is not None
    assert result.compare.passed is True
    assert result.capture_path is None
    assert result.diff_path is None


def test_run_baseline_mismatched_capture_writes_failure_artifact(
    monkeypatch, tmp_root
):
    """Fixture baseline + grab returning a drifted image -> fail +
    artifact written under failures/."""
    name = "scene_fail"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(name=name, renderer=lambda: _StubWidget())
    )
    # Baseline is uniform 128-gray.
    baseline_path = baselines_dir(tmp_root) / f"{name}.png"
    _solid_image((32, 32), 128).save(baseline_path)
    # Make the grabber return a split image instead.
    monkeypatch.setattr(
        capture, "_GRAB_HOOK",
        lambda bbox: _split_image((bbox[2] - bbox[0], bbox[3] - bbox[1])),
    )

    result = run_baseline(name, manifest=manifest, root=tmp_root)

    assert result.passed is False
    assert result.status == "fail"
    assert result.compare is not None
    assert result.compare.passed is False
    assert result.capture_path is not None
    assert result.capture_path.exists()
    assert result.capture_path.parent == failures_dir(tmp_root)
    assert result.capture_path.suffix == ".png"
    assert result.diff_path is not None
    assert result.diff_path.exists()
    # Filename pattern: <name>_<timestamp>.png.
    assert result.capture_path.name.startswith(f"{name}_")


def test_run_baseline_unknown_baseline(tmp_root):
    """A name that isn't registered surfaces as unknown_baseline,
    not as a Python exception."""
    manifest = BaselineManifest()  # empty
    result = run_baseline("nope", manifest=manifest, root=tmp_root)
    assert result.status == "unknown_baseline"
    assert result.passed is False
    assert "nope" in (result.error or "")


def test_run_baseline_missing_baseline_png(tmp_root):
    """Registered baseline but no PNG yet -> baseline_missing status,
    no failure artifact written."""
    name = "scene_no_png"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(name=name, renderer=lambda: _StubWidget())
    )
    result = run_baseline(name, manifest=manifest, root=tmp_root)
    assert result.status == "baseline_missing"
    assert result.passed is False
    assert result.capture_path is None
    assert "SPEC-069" in (result.error or "")


def test_run_baseline_renderer_exception_surfaces_as_capture_error(tmp_root):
    name = "scene_renderer_boom"
    manifest = BaselineManifest()

    def boom():
        raise RuntimeError("renderer intentionally exploded")

    manifest.register(BaselineSpec(name=name, renderer=boom))
    result = run_baseline(name, manifest=manifest, root=tmp_root)
    assert result.status == "capture_error"
    assert "exploded" in (result.error or "")


def test_run_baseline_headless_capture_surfaces_as_headless(
    monkeypatch, tmp_root
):
    name = "scene_headless"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(name=name, renderer=lambda: _StubWidget())
    )
    monkeypatch.setattr(capture, "_GRAB_HOOK", lambda bbox: None)
    result = run_baseline(name, manifest=manifest, root=tmp_root)
    assert result.status == "headless"
    assert result.passed is False


def test_per_baseline_threshold_overrides_default(monkeypatch, tmp_root):
    """A spec.threshold of 0.5 lets a drifted capture pass when
    the default 0.98 would fail."""
    name = "scene_loose"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(
            name=name,
            renderer=lambda: _StubWidget(),
            threshold=0.1,
        )
    )
    baseline_path = baselines_dir(tmp_root) / f"{name}.png"
    _solid_image((32, 32), 128).save(baseline_path)
    monkeypatch.setattr(
        capture, "_GRAB_HOOK",
        lambda bbox: _split_image((bbox[2] - bbox[0], bbox[3] - bbox[1])),
    )
    result = run_baseline(name, manifest=manifest, root=tmp_root)
    # Threshold 0.1 is very loose — even the split image should clear it.
    assert result.passed is True
    assert result.compare.threshold == 0.1


def test_explicit_threshold_arg_overrides_spec(monkeypatch, tmp_root):
    name = "scene_override"
    manifest = BaselineManifest()
    manifest.register(
        BaselineSpec(
            name=name,
            renderer=lambda: _StubWidget(),
            threshold=0.1,
        )
    )
    baseline_path = baselines_dir(tmp_root) / f"{name}.png"
    _solid_image((32, 32), 128).save(baseline_path)
    monkeypatch.setattr(
        capture, "_GRAB_HOOK",
        lambda bbox: _split_image((bbox[2] - bbox[0], bbox[3] - bbox[1])),
    )
    # Explicit arg supersedes the spec's loose threshold.
    result = run_baseline(
        name, manifest=manifest, root=tmp_root, threshold=0.99,
    )
    assert result.passed is False
    assert result.compare.threshold == 0.99


# ---------------------------------------------------------------------------
# Manifest + RunnerResult basics.
# ---------------------------------------------------------------------------


def test_runner_result_has_passed_property():
    r = RunnerResult(name="x", status="pass")
    assert r.passed is True
    r2 = RunnerResult(name="x", status="fail")
    assert r2.passed is False
