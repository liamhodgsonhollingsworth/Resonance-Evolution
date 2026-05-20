"""
Visual regression runner — SPEC-080.

Orchestrates capture -> compare -> write-failure-artifact for one
registered baseline. The full pipeline shape:

1. Look up the baseline by name in the manifest.
2. Resolve the baseline PNG path under
   ``tests/visual_regression/baselines/<name>.png``.
3. Invoke the manifest entry's renderer to obtain a Tk widget.
4. Pump + capture the widget via :func:`tools.visual_regression.capture.capture_widget`.
5. If a baseline PNG exists, compare via
   :func:`tools.visual_regression.compare.compare_images`. If not,
   the runner reports baseline-missing without failing — tests can
   decide whether that's acceptable.
6. On mismatch, write the fresh capture + the diff image to
   ``tests/visual_regression/failures/<name>_<timestamp>.png`` so the
   maintainer can review.

The runner exposes both a programmatic entry-point
(:func:`run_baseline`) and helpers for resolving the canonical
artifact directories.

Path resolution is centralised here so a future move of the test
artifact tree (e.g. into a sibling repo) lands in exactly one place.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

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
from tools.visual_regression.manifest import (
    BaselineManifest,
    BaselineSpec,
    default_manifest,
)


# Repo-root relative artifact tree.
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BASELINES_REL = Path("tests") / "visual_regression" / "baselines"
_FAILURES_REL = Path("tests") / "visual_regression" / "failures"


def baselines_dir(root: Optional[Path] = None) -> Path:
    """Path to the directory that owns baseline PNGs.

    Resolves to ``<root>/tests/visual_regression/baselines`` (default
    root = the Apeiron repo). The directory is created on first
    access so the runner never trips over a missing parent.
    """
    base = (root or _REPO_ROOT) / _BASELINES_REL
    base.mkdir(parents=True, exist_ok=True)
    return base


def failures_dir(root: Optional[Path] = None) -> Path:
    """Path to the directory that owns failure artifacts.

    Resolves to ``<root>/tests/visual_regression/failures``. Created
    on first access for the same reason as :func:`baselines_dir`.
    """
    base = (root or _REPO_ROOT) / _FAILURES_REL
    base.mkdir(parents=True, exist_ok=True)
    return base


@dataclass
class RunnerResult:
    """Verdict from one :func:`run_baseline` invocation.

    Attributes:
        name: Baseline name.
        status: One of ``"pass"``, ``"fail"``, ``"baseline_missing"``,
            ``"capture_error"``, ``"headless"``, ``"unknown_baseline"``.
        compare: The :class:`CompareResult`, present when capture +
            compare both ran successfully.
        baseline_path: Resolved baseline PNG path (may not exist on
            disk for ``baseline_missing`` / ``unknown_baseline``).
        capture_path: Where the fresh capture was written for failure
            review. ``None`` on pass.
        diff_path: Where the diff visualisation was written.
            ``None`` on pass.
        error: Human-readable error string for non-comparison
            failures.
    """

    name: str
    status: str
    compare: Optional[CompareResult] = None
    baseline_path: Optional[Path] = None
    capture_path: Optional[Path] = None
    diff_path: Optional[Path] = None
    error: Optional[str] = None

    @property
    def passed(self) -> bool:
        return self.status == "pass"


def _timestamp_slug() -> str:
    """Filesystem-safe UTC timestamp slug for failure artifacts."""
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def _resolve_baseline(
    name: str, manifest: BaselineManifest
) -> Optional[BaselineSpec]:
    return manifest.get(name)


def _write_failure_artifacts(
    name: str,
    fresh: Any,
    compare_result: CompareResult,
    failures: Path,
) -> tuple[Path, Path]:
    """Persist the fresh capture + diff image with a shared timestamp."""
    slug = _timestamp_slug()
    capture_path = failures / f"{name}_{slug}.png"
    diff_path = failures / f"{name}_{slug}_diff.png"
    try:
        fresh.save(capture_path, format="PNG")
    except Exception as exc:
        raise CaptureError(
            f"failed to write failure artifact at {capture_path}: {exc}"
        ) from exc
    try:
        compare_result.diff_image.save(diff_path, format="PNG")
    except Exception as exc:
        raise CaptureError(
            f"failed to write diff artifact at {diff_path}: {exc}"
        ) from exc
    return capture_path, diff_path


def run_baseline(
    name: str,
    *,
    manifest: Optional[BaselineManifest] = None,
    root: Optional[Path] = None,
    threshold: Optional[float] = None,
) -> RunnerResult:
    """Run the capture -> compare cycle for one registered baseline.

    Args:
        name: Baseline name (must be registered in *manifest*).
        manifest: Manifest to consult. Defaults to the process-wide
            singleton (see :func:`default_manifest`).
        root: Repo root override (tests typically pass ``tmp_path``).
        threshold: Override the SSIM threshold for this run.
            Resolution order: explicit arg, spec.threshold, runner
            default 0.98.

    Returns:
        A :class:`RunnerResult` describing the outcome.

    The runner does not raise on capture failure — it catches
    :exc:`CaptureError` and returns a result with the appropriate
    status. This keeps the test-side ergonomics simple
    (``assert result.passed``).
    """
    manifest = manifest if manifest is not None else default_manifest()
    spec = _resolve_baseline(name, manifest)
    if spec is None:
        return RunnerResult(
            name=name,
            status="unknown_baseline",
            error=f"no baseline named {name!r} in manifest",
        )

    effective_threshold = (
        threshold
        if threshold is not None
        else (spec.threshold if spec.threshold is not None else DEFAULT_SSIM_THRESHOLD)
    )
    baseline_path = baselines_dir(root) / f"{name}.png"

    try:
        widget = spec.renderer()
    except Exception as exc:
        return RunnerResult(
            name=name,
            status="capture_error",
            baseline_path=baseline_path,
            error=f"renderer hook for {name!r} raised: {exc}",
        )

    try:
        fresh = capture_widget(widget)
    except HeadlessCaptureError as exc:
        return RunnerResult(
            name=name,
            status="headless",
            baseline_path=baseline_path,
            error=str(exc),
        )
    except CaptureError as exc:
        return RunnerResult(
            name=name,
            status="capture_error",
            baseline_path=baseline_path,
            error=str(exc),
        )

    if not baseline_path.exists():
        # Scaffolding-friendly: an unknown-baseline isn't an error
        # — SPEC-069 will populate them. Surface the verdict so the
        # caller can decide.
        return RunnerResult(
            name=name,
            status="baseline_missing",
            baseline_path=baseline_path,
            error=(
                f"no baseline at {baseline_path}; "
                f"establish a baseline before treating mismatches as "
                f"regressions (SPEC-069 wires production baselines)"
            ),
        )

    try:
        from PIL import Image
        baseline_img = Image.open(baseline_path)
    except Exception as exc:
        return RunnerResult(
            name=name,
            status="capture_error",
            baseline_path=baseline_path,
            error=f"could not open baseline PNG at {baseline_path}: {exc}",
        )

    compare_result = compare_images(baseline_img, fresh, threshold=effective_threshold)

    if compare_result.passed:
        return RunnerResult(
            name=name,
            status="pass",
            compare=compare_result,
            baseline_path=baseline_path,
        )

    failures = failures_dir(root)
    capture_path, diff_path = _write_failure_artifacts(
        name, fresh, compare_result, failures
    )
    return RunnerResult(
        name=name,
        status="fail",
        compare=compare_result,
        baseline_path=baseline_path,
        capture_path=capture_path,
        diff_path=diff_path,
    )
