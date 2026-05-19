"""
Tests for the realtime renderer driver and tkinter backend.

All tests run headlessly — no Tk window is opened in CI. The Tk backend's
event-translation helpers are pure functions; the driver is tested against
a stub backend that records what was blitted and feeds canned events.

The integration test opens a real workflow_view scene, drives one frame
through the stub backend, and verifies the color channel arrives shaped
HxWx3 with the WorkflowView panels visible.
"""

from __future__ import annotations

import sys
from collections import deque
from pathlib import Path
from typing import Deque, List, Optional

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.input import Bindings, InputEvent  # noqa: E402
from engine.realtime import (  # noqa: E402
    RealtimeDriver,
    escape_toggles_workflow_mode_or_quits,
)
from engine.realtime_tk import normalize_tk_key  # noqa: E402


# ---------------------------------------------------------------------------
# Stub backend — drives the loop headlessly.
# ---------------------------------------------------------------------------


class StubBackend:
    """A WindowBackend that records every call. Tests feed events via
    ``queue_events`` and inspect ``blits`` / ``closed`` after frames."""

    def __init__(self) -> None:
        self.events: Deque[InputEvent] = deque()
        self.blits: List[np.ndarray] = []
        self.opened = False
        self.closed = False
        self.titles: List[str] = []
        self._should_close = False
        self.open_args: Optional[tuple] = None

    def queue_events(self, *events: InputEvent) -> None:
        self.events.extend(events)

    def signal_close(self) -> None:
        self._should_close = True

    # WindowBackend surface
    def open(self, width: int, height: int, title: str = "Apeiron") -> None:
        self.opened = True
        self.open_args = (width, height, title)

    def poll_events(self) -> List[InputEvent]:
        out = list(self.events)
        self.events.clear()
        return out

    def blit_color(self, color_array: np.ndarray) -> None:
        self.blits.append(np.asarray(color_array).copy())

    def should_close(self) -> bool:
        return self._should_close

    def close(self) -> None:
        self.closed = True

    def set_title(self, title: str) -> None:
        self.titles.append(title)


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------


@pytest.fixture
def engine_with_scene():
    """Real engine loaded with the workflow_view scene."""
    e = Engine(root_dir=ROOT)
    e.discover()
    root = e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.precompute()
    return e, root


@pytest.fixture
def driver_for_workflow(engine_with_scene):
    engine, root_id = engine_with_scene
    view = View(width=128, height=96)
    return RealtimeDriver(engine=engine, root_id=root_id, view=view, frame_budget_s=0.0)


# ---------------------------------------------------------------------------
# Tk key-name translation — pure helper, no Tk needed.
# ---------------------------------------------------------------------------


def test_normalize_tk_key_lowercases_letters():
    assert normalize_tk_key("w") == "w"
    assert normalize_tk_key("A") == "a"


def test_normalize_tk_key_maps_specials():
    assert normalize_tk_key("Escape") == "escape"
    assert normalize_tk_key("Return") == "enter"
    assert normalize_tk_key("space") == "space"
    assert normalize_tk_key("Shift_L") == "shift"


def test_normalize_tk_key_unknown_falls_through_lowercased():
    assert normalize_tk_key("SuperKey") == "superkey"


# ---------------------------------------------------------------------------
# Driver: process_event resolves to ViewMutations via Bindings.
# ---------------------------------------------------------------------------


def test_process_event_translates_wasd_to_mutation(driver_for_workflow):
    driver = driver_for_workflow
    event = InputEvent(kind="key_down", key="w", timestamp=0.0)
    consumed, mutations = driver.process_event(event)
    assert consumed is False
    assert len(mutations) == 1
    # WASD default moves in z=-1 direction (forward in viewer's local frame).
    delta = mutations[0].delta_position
    assert delta is not None
    assert delta[2] < 0


def test_process_event_records_held_key(driver_for_workflow):
    driver = driver_for_workflow
    driver.process_event(InputEvent(kind="key_down", key="w", timestamp=1.0))
    assert "w" in driver.binding_context.held_keys
    driver.process_event(InputEvent(kind="key_up", key="w", timestamp=1.5))
    assert "w" not in driver.binding_context.held_keys


# ---------------------------------------------------------------------------
# Driver: assemble + blit produce HxWx3 uint8 output.
# ---------------------------------------------------------------------------


def test_run_one_frame_blits_color_shape(driver_for_workflow):
    backend = StubBackend()
    backend.open(128, 96, "test")
    driver = driver_for_workflow
    stats = driver.run_one_frame(backend)
    assert stats.frame_index == 1
    assert stats.color_shape is not None
    assert stats.color_shape[2] == 3
    assert len(backend.blits) == 1
    blitted = backend.blits[0]
    assert blitted.ndim == 3
    assert blitted.shape[2] == 3
    assert blitted.dtype == np.uint8


def test_run_one_frame_applies_movement(driver_for_workflow):
    backend = StubBackend()
    backend.open(64, 64, "test")
    driver = driver_for_workflow
    p0 = driver.view.position.copy()
    backend.queue_events(InputEvent(kind="key_down", key="w", timestamp=0.0))
    driver.run_one_frame(backend)
    # Forward in default orientation is -Z (look_at default), so position[2] decreases.
    assert driver.view.position[2] < p0[2]


def test_run_one_frame_survives_assemble_error(driver_for_workflow, monkeypatch):
    driver = driver_for_workflow

    def boom(*args, **kwargs):
        raise RuntimeError("simulated assemble failure")

    monkeypatch.setattr(driver.engine, "assemble", boom)
    backend = StubBackend()
    backend.open(32, 32, "test")
    stats = driver.run_one_frame(backend)
    # Loop did not raise; the placeholder fallback blitted a frame so the
    # window doesn't go blank.
    assert stats.assemble_error is not None
    assert "simulated" in stats.assemble_error
    assert len(backend.blits) == 1


# ---------------------------------------------------------------------------
# Global handlers: Escape toggles WorkflowView mode.
# ---------------------------------------------------------------------------


def test_escape_toggles_workflow_view_mode(driver_for_workflow):
    driver = driver_for_workflow
    workflow_root = driver.engine.nodes[driver.root_id]
    assert workflow_root.type_name == "WorkflowView"
    assert workflow_root.state["mode"] == "panels"
    event = InputEvent(kind="key_down", key="escape", timestamp=0.0)
    consumed = escape_toggles_workflow_mode_or_quits(event, driver)
    assert consumed is True
    assert workflow_root.state["mode"] == "full_render"
    # Toggling again returns to panels.
    escape_toggles_workflow_mode_or_quits(event, driver)
    assert workflow_root.state["mode"] == "panels"


def test_escape_quits_when_root_not_workflow_view():
    engine = Engine(root_dir=ROOT)
    engine.discover()
    engine.spawn("Cube", "cube0", {"size": 1.0})
    driver = RealtimeDriver(
        engine=engine, root_id="cube0", view=View(width=16, height=16), frame_budget_s=0.0
    )
    event = InputEvent(kind="key_down", key="escape", timestamp=0.0)
    consumed = escape_toggles_workflow_mode_or_quits(event, driver)
    assert consumed is True
    assert driver._quit_requested is True


def test_escape_event_is_consumed_globally(driver_for_workflow):
    backend = StubBackend()
    backend.open(32, 32, "test")
    driver = driver_for_workflow
    backend.queue_events(InputEvent(kind="key_down", key="escape", timestamp=0.0))
    stats = driver.run_one_frame(backend)
    assert stats.consumed_globally == 1


# ---------------------------------------------------------------------------
# Driver: run-loop honors should_quit and max_frames.
# ---------------------------------------------------------------------------


def test_run_stops_on_backend_close(driver_for_workflow):
    backend = StubBackend()
    backend.open(32, 32, "test")
    driver = driver_for_workflow
    backend.signal_close()
    rendered = driver.run(backend)
    assert rendered == 0
    assert backend.closed is True


def test_run_stops_after_max_frames(driver_for_workflow):
    backend = StubBackend()
    backend.open(32, 32, "test")
    driver = driver_for_workflow
    rendered = driver.run(backend, max_frames=3)
    assert rendered == 3
    assert len(backend.blits) == 3
    assert backend.closed is True


def test_run_quits_when_driver_request_quit(driver_for_workflow):
    backend = StubBackend()
    backend.open(32, 32, "test")
    driver = driver_for_workflow
    driver.request_quit()
    rendered = driver.run(backend)
    assert rendered == 0


# ---------------------------------------------------------------------------
# Color-normalization: float in 0..1 → uint8 in 0..255; RGBA → RGB.
# ---------------------------------------------------------------------------


def test_normalize_color_uint8_passes_through():
    arr = np.zeros((4, 6, 3), dtype=np.uint8)
    out = RealtimeDriver._normalize_color(arr)
    assert out.dtype == np.uint8
    assert out.shape == (4, 6, 3)


def test_normalize_color_float_scaled_to_uint8():
    arr = np.ones((2, 3, 3), dtype=np.float32) * 0.5
    out = RealtimeDriver._normalize_color(arr)
    assert out.dtype == np.uint8
    assert out[0, 0, 0] == 127


def test_normalize_color_rgba_drops_alpha():
    arr = np.zeros((2, 2, 4), dtype=np.uint8)
    out = RealtimeDriver._normalize_color(arr)
    assert out.shape == (2, 2, 3)


# ---------------------------------------------------------------------------
# Backend discovery — at minimum tk is available on a Python build with tkinter.
# ---------------------------------------------------------------------------


def test_available_backends_includes_tk_when_tkinter_importable():
    try:
        import tkinter  # noqa: F401
    except Exception:
        pytest.skip("tkinter not available")
    from engine.realtime import available_backends

    names = available_backends()
    assert "tk" in names


def test_make_backend_unknown_name_raises():
    from engine.realtime import make_backend

    with pytest.raises(RuntimeError, match="unknown realtime backend"):
        make_backend("nonexistent")
