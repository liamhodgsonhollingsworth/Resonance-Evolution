"""
Tests for SPEC-080 visual-regression capture surface.

Exercises the bounding-box math + the grab-hook seam against a stub
Tk-shaped widget so the suite runs anywhere (headless CI included).
The real ``PIL.ImageGrab.grab`` path is not exercised — it requires
a live display — but the capture function defers to a swappable
grabber so we cover its orchestration.
"""

from __future__ import annotations

from typing import Any

import pytest
from PIL import Image

from tools.visual_regression import capture
from tools.visual_regression.capture import (
    CaptureError,
    HeadlessCaptureError,
    capture_widget,
)


class _StubWidget:
    """Minimum Tk-widget protocol for the capture surface.

    Tracks how many times update / update_idletasks were called so
    tests can assert the pump cycle ran.
    """

    def __init__(
        self,
        *,
        x: int = 100,
        y: int = 50,
        w: int = 64,
        h: int = 48,
        raise_on_update: bool = False,
    ) -> None:
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.update_idletasks_calls = 0
        self.update_calls = 0
        self.raise_on_update = raise_on_update

    # Tk protocol.
    def winfo_rootx(self) -> int:
        return self.x

    def winfo_rooty(self) -> int:
        return self.y

    def winfo_width(self) -> int:
        return self.w

    def winfo_height(self) -> int:
        return self.h

    def update_idletasks(self) -> None:
        self.update_idletasks_calls += 1

    def update(self) -> None:
        if self.raise_on_update:
            raise RuntimeError("update intentionally failed")
        self.update_calls += 1


@pytest.fixture(autouse=True)
def _no_pump_sleep(monkeypatch):
    """Tests should not sleep — drop the pump delay to zero."""
    monkeypatch.setattr(capture, "_PUMP_DELAY_S", 0.0)
    yield


@pytest.fixture
def reset_grab_hook():
    """Restore the grab hook between tests."""
    original = capture._GRAB_HOOK
    yield
    capture._GRAB_HOOK = original


# ---------------------------------------------------------------------------
# Happy path.
# ---------------------------------------------------------------------------


def test_capture_returns_pil_image_with_expected_dims(reset_grab_hook):
    """A widget reporting 64x48 produces a 64x48 PIL.Image."""
    widget = _StubWidget(x=10, y=20, w=64, h=48)
    captured_bbox: list = []

    def fake_grab(bbox: tuple, **_: Any) -> Image.Image:
        captured_bbox.append(bbox)
        # Produce an actual PIL.Image of the requested size.
        return Image.new("RGB", (bbox[2] - bbox[0], bbox[3] - bbox[1]),
                         color=(20, 20, 20))

    capture._GRAB_HOOK = fake_grab

    img = capture_widget(widget)

    assert isinstance(img, Image.Image)
    assert img.size == (64, 48)
    # bbox is (left, top, right, bottom).
    assert captured_bbox == [(10, 20, 74, 68)]
    # Pump cycle ran (one update_idletasks + two updates).
    assert widget.update_idletasks_calls == 1
    assert widget.update_calls == 2


def test_capture_supports_grab_returning_rgba(reset_grab_hook):
    """RGBA images pass through unchanged — the runner cares about
    size + content, not mode."""
    widget = _StubWidget(w=32, h=32)
    capture._GRAB_HOOK = lambda bbox: Image.new(
        "RGBA", (32, 32), color=(0, 0, 0, 255)
    )
    img = capture_widget(widget)
    assert img.mode == "RGBA"
    assert img.size == (32, 32)


# ---------------------------------------------------------------------------
# Headless / failure surface.
# ---------------------------------------------------------------------------


def test_capture_raises_headless_when_grab_returns_none(reset_grab_hook):
    widget = _StubWidget()
    capture._GRAB_HOOK = lambda bbox: None
    with pytest.raises(HeadlessCaptureError) as exc:
        capture_widget(widget)
    assert "None" in str(exc.value)


def test_capture_promotes_display_errors_to_headless(reset_grab_hook):
    widget = _StubWidget()

    def boom(bbox):
        raise RuntimeError("no DISPLAY available")

    capture._GRAB_HOOK = boom
    with pytest.raises(HeadlessCaptureError) as exc:
        capture_widget(widget)
    assert "display" in str(exc.value).lower()


def test_capture_other_grab_errors_surface_as_capture_error(reset_grab_hook):
    widget = _StubWidget()

    def boom(bbox):
        raise RuntimeError("some unrelated I/O failure")

    capture._GRAB_HOOK = boom
    with pytest.raises(CaptureError) as exc:
        capture_widget(widget)
    assert not isinstance(exc.value, HeadlessCaptureError)
    assert "I/O" in str(exc.value)


def test_capture_rejects_unmapped_widget(reset_grab_hook):
    """Zero-dimension widget means it was never mapped to screen.
    Don't silently produce a 0x0 PNG."""
    widget = _StubWidget(w=0, h=0)
    with pytest.raises(CaptureError) as exc:
        capture_widget(widget)
    assert "non-positive" in str(exc.value) or "mapped" in str(exc.value)


def test_capture_rejects_widget_without_winfo(reset_grab_hook):
    class NotAWidget:
        pass

    with pytest.raises(CaptureError) as exc:
        capture_widget(NotAWidget())
    assert "winfo" in str(exc.value)


def test_capture_rejects_grab_returning_zero_size(reset_grab_hook):
    widget = _StubWidget(w=32, h=32)

    def degenerate(bbox):
        return Image.new("RGB", (0, 0))

    capture._GRAB_HOOK = degenerate
    with pytest.raises(CaptureError) as exc:
        capture_widget(widget)
    assert "non-positive" in str(exc.value)


def test_capture_propagates_update_failure(reset_grab_hook):
    widget = _StubWidget(raise_on_update=True)
    capture._GRAB_HOOK = lambda bbox: Image.new("RGB", (1, 1))
    with pytest.raises(CaptureError) as exc:
        capture_widget(widget)
    assert "update" in str(exc.value)


# ---------------------------------------------------------------------------
# is_display_available probe.
# ---------------------------------------------------------------------------


def test_is_display_available_returns_bool():
    """Sanity: the probe doesn't raise and returns a bool."""
    assert isinstance(capture.is_display_available(), bool)
