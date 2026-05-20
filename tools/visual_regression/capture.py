"""
Capture a screenshot of a Tk widget — SPEC-080.

Wraps ``PIL.ImageGrab.grab`` against the widget's screen bounding box
(``winfo_rootx/rooty/width/height``). The widget must be mapped to the
screen at capture time — ``ImageGrab.grab`` reads on-screen pixels, so
minimised, off-screen, or never-mapped widgets return either an error
or the wrong content.

Per the design doc, on Windows ``ImageGrab.grab`` is the simplest path
that captures the full widget including child widgets without ctypes
or PrintWindow. The headless case (no display, no Tk widget mapped)
is surfaced as a clear :class:`HeadlessCaptureError` rather than a
silent blank image — silent blanks would corrupt baselines.

Two seams worth knowing about:

- ``_PUMP_DELAY_S`` is the post-``update`` sleep that absorbs Tk's
  async paint scheduling. The design doc settled on 100ms; the
  module-level constant lets tests adjust it without monkey-patching.
- ``_GRAB_HOOK`` defaults to ``PIL.ImageGrab.grab``. Tests substitute
  a fake to exercise the bounding-box math without a real display.

Public API:

- :func:`capture_widget` — capture a Tk widget's bounding box and
  return a PIL.Image.
- :exc:`CaptureError` — base for capture-time failures.
- :exc:`HeadlessCaptureError` — no display available.
"""

from __future__ import annotations

import sys
import time
from typing import Any, Callable, Optional


# Hook for tests: lets tests swap in a fake grabber without a display.
_GRAB_HOOK: Optional[Callable[..., Any]] = None

# Post-update sleep absorbing Tk's async paint scheduling. 100ms is
# the design doc's recommended value.
_PUMP_DELAY_S: float = 0.1


class CaptureError(RuntimeError):
    """Raised when a capture cannot complete successfully."""


class HeadlessCaptureError(CaptureError):
    """Raised when capture is attempted without a usable display.

    The message identifies the specific reason (no display variable,
    grab returned None, etc.) so the caller can decide whether to
    skip, retry, or fail the run.
    """


def _resolve_grabber() -> Callable[..., Any]:
    """Return the active grab function — the hook if set, else PIL's."""
    if _GRAB_HOOK is not None:
        return _GRAB_HOOK
    try:
        from PIL import ImageGrab
    except ImportError as exc:  # pragma: no cover - PIL is a hard dep
        raise CaptureError(f"PIL.ImageGrab unavailable: {exc}") from exc
    return ImageGrab.grab


def _widget_bbox(widget: Any) -> tuple[int, int, int, int]:
    """Return (left, top, right, bottom) on-screen for a Tk widget.

    Raises :exc:`CaptureError` if the widget reports a zero-dimension
    rectangle — that means it hasn't been mapped yet, which would
    silently produce a 0x0 image.
    """
    try:
        x = int(widget.winfo_rootx())
        y = int(widget.winfo_rooty())
        w = int(widget.winfo_width())
        h = int(widget.winfo_height())
    except Exception as exc:
        raise CaptureError(
            f"widget does not expose winfo_rootx/rooty/width/height: {exc}"
        ) from exc
    if w <= 0 or h <= 0:
        raise CaptureError(
            f"widget bbox has non-positive dimensions ({w}x{h}); "
            f"widget probably not mapped to screen yet"
        )
    return (x, y, x + w, y + h)


def _pump(widget: Any) -> None:
    """Force the widget to lay out + render before capture.

    Two ``update`` calls (one for layout, one for paint) plus a short
    sleep is the design-doc-validated incantation. Per the design doc,
    Tk paints async — a single ``update`` schedules the paint but
    doesn't wait on the window manager.
    """
    # ``update_idletasks`` flushes pending layout work; ``update``
    # then flushes any new events that work generated. Per design,
    # call both, then update one more time after the sleep.
    try:
        widget.update_idletasks()
        widget.update()
    except Exception as exc:
        raise CaptureError(f"widget update raised: {exc}") from exc
    if _PUMP_DELAY_S > 0:
        time.sleep(_PUMP_DELAY_S)
    try:
        widget.update()
    except Exception as exc:
        raise CaptureError(f"widget post-sleep update raised: {exc}") from exc


def capture_widget(widget: Any) -> Any:
    """Capture *widget*'s on-screen bounding box as a PIL.Image.

    ``widget`` must expose the Tk widget protocol — ``winfo_rootx``,
    ``winfo_rooty``, ``winfo_width``, ``winfo_height``,
    ``update_idletasks``, ``update``. Any object that quacks like a
    Tk widget works; tests substitute plain stub objects.

    Returns the captured ``PIL.Image.Image``. Caller is responsible
    for saving to disk if persistence is wanted.

    Raises:

    - :exc:`HeadlessCaptureError` — grabber returned ``None`` or the
      environment has no display.
    - :exc:`CaptureError` — widget unmapped, grabber raised, or the
      returned image is empty.
    """
    bbox = _widget_bbox(widget)
    _pump(widget)
    grab = _resolve_grabber()
    try:
        img = grab(bbox=bbox)
    except Exception as exc:
        # On many platforms PIL.ImageGrab raises with a clear message
        # when no display is available; promote that to the headless
        # exception so callers can branch on it.
        message = str(exc).lower()
        if any(
            tok in message
            for tok in ("display", "x server", "screen", "headless")
        ):
            raise HeadlessCaptureError(
                f"capture failed with display-related error: {exc}"
            ) from exc
        raise CaptureError(f"ImageGrab.grab raised: {exc}") from exc

    if img is None:
        raise HeadlessCaptureError(
            "ImageGrab.grab returned None; "
            "likely no display available or widget is off-screen"
        )

    # Validate non-empty result so a malformed grabber doesn't write
    # a 0x0 PNG as a baseline.
    try:
        width, height = img.size
    except Exception as exc:
        raise CaptureError(f"captured image has no size attribute: {exc}") from exc
    if width <= 0 or height <= 0:
        raise CaptureError(
            f"captured image has non-positive dimensions ({width}x{height})"
        )
    return img


def is_display_available() -> bool:
    """Cheap precheck — does the platform appear to have a usable display?

    Windows always returns True (the design doc's target platform).
    Linux/macOS returns True only when ``$DISPLAY`` is set. Used by
    callers that want to skip rather than raise.
    """
    if sys.platform.startswith("win"):
        return True
    if sys.platform == "darwin":  # pragma: no cover - non-target
        return True
    import os
    return bool(os.environ.get("DISPLAY"))
