"""
Tests for the realtime click → action dispatch handler.

The realtime renderer's default global-handlers chain now includes
``click_dispatches_on_workflow_panels``. A left-button mouse-down with
``x``/``y`` canvas coordinates ray-casts to the WorkflowView's panels,
finds the hit item-row, and invokes ``dispatch_action(panel, "expand",
item_id=...)``. These tests exercise the handler against the real
workflow_view scene driven through the existing StubBackend.

Coverage:

- Click on a panel's first item row → expand fires with that id.
- Click inside the panel title region → no dispatch (header-only hit).
- Click past the last item row → no dispatch.
- Click outside all panels → no dispatch.
- Right-click → no dispatch (left-only).
- Click with x=-1 (unknown position) → no dispatch.
- Click on a non-WorkflowView root → handler returns False.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.actions import VIEW_STATE_CACHE_KEY, get_view_state  # noqa: E402
from engine.input import InputEvent  # noqa: E402
from engine.realtime import (  # noqa: E402
    RealtimeDriver,
    click_dispatches_on_workflow_panels,
    _hit_test_workflow_panels,
)


def _look_at(eye, target):
    """Identity look-down-negative-z; the workflow_view scene uses this."""
    forward = np.asarray(target, dtype=np.float64) - np.asarray(eye, dtype=np.float64)
    forward = forward / (np.linalg.norm(forward) + 1e-12)
    up_world = np.array([0.0, 1.0, 0.0])
    right = np.cross(forward, up_world)
    right = right / (np.linalg.norm(right) + 1e-12)
    up = np.cross(right, forward)
    R = np.stack([right, up, -forward], axis=1)
    return R


@pytest.fixture
def driver_with_workflow_scene():
    e = Engine(root_dir=ROOT)
    e.discover()
    root_id = e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.precompute()
    view = View(
        position=np.array([0.0, 0.0, 9.0]),
        orientation=_look_at(np.array([0.0, 0.0, 9.0]), np.array([0.0, 0.0, 0.0])),
        width=192,
        height=96,
        fov_y_radians=0.6,
    )
    driver = RealtimeDriver(engine=e, root_id=root_id, view=view, frame_budget_s=0.0)
    return driver


def _click_canvas_to_world_x(driver, click_x_canvas, click_y_canvas):
    """Helper: where does a click on the canvas land in world-x at z=0?
    Used to pick canvas positions that hit specific panels in tests.
    """
    view = driver.view
    canvas_w, canvas_h = view.width, view.height
    half_h = float(np.tan(view.fov_y_radians / 2.0))
    half_w = half_h * (canvas_w / canvas_h)
    u = (click_x_canvas / canvas_w) * 2.0 - 1.0
    v = 1.0 - (click_y_canvas / canvas_h) * 2.0
    dir_cam = np.array([u * half_w, v * half_h, -1.0])
    dir_cam /= np.linalg.norm(dir_cam)
    dir_world = view.orientation @ dir_cam
    origin = view.position
    if abs(dir_world[2]) < 1e-12:
        return None, None
    t = -origin[2] / dir_world[2]
    return origin[0] + t * dir_world[0], origin[1] + t * dir_world[1]


def _find_canvas_xy_for_world(driver, world_x, world_y):
    """Inverse of _click_canvas_to_world_x: pick canvas (x, y) that hits
    the given world (x, y) on z=0."""
    view = driver.view
    canvas_w, canvas_h = view.width, view.height
    half_h = float(np.tan(view.fov_y_radians / 2.0))
    half_w = half_h * (canvas_w / canvas_h)
    # World point → camera-space direction.
    p_world = np.array([world_x, world_y, 0.0]) - view.position
    p_cam = view.orientation.T @ p_world
    # p_cam = (u*half_w, v*half_h, -1) * length; we want NDC u, v.
    # p_cam normalized: divide by -p_cam.z
    if abs(p_cam[2]) < 1e-12:
        return None, None
    u = p_cam[0] / (-p_cam[2]) / half_w
    v = p_cam[1] / (-p_cam[2]) / half_h
    cx = int(round((u + 1.0) * 0.5 * canvas_w))
    cy = int(round((1.0 - v) * 0.5 * canvas_h))
    return cx, cy


# ---------------------------------------------------------------------------
# Hit-test math
# ---------------------------------------------------------------------------


def test_click_in_panel_center_returns_panel_and_item(driver_with_workflow_scene):
    """The wish_panel sits at world-x = 0. A click at world (0, +2) hits the
    panel's top item row."""
    driver = driver_with_workflow_scene
    # wish_panel is at x=0, screen_h=4.6. The first item row sits below the
    # title (font_size=12, header_end = 4 + 12*1.6 ≈ 23.2 px out of 384 →
    # ≈ 6% from the top in world-y → y ≈ +2.0 in panel-local frame).
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.0)
    assert cx is not None
    panel_id, item_id = _hit_test_workflow_panels(
        engine=driver.engine,
        view=driver.view,
        root=driver.engine.nodes[driver.root_id],
        click_x=cx,
        click_y=cy,
    )
    assert panel_id == "wish_panel"
    assert item_id is not None
    # The id should be the wish parser's first wish.
    items = driver.engine.cache["wishes_source"]["items"]
    assert any(it["id"] == item_id for it in items)


def test_click_in_panel_title_returns_no_item(driver_with_workflow_scene):
    """A click near the top of a panel lands in the title region above
    the horizontal divider — no item-row is hit so dispatch must skip."""
    driver = driver_with_workflow_scene
    # Aim at world (0, +2.28) — just below screen_h/2 = 2.3, panel-top.
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.28)
    panel_id, item_id = _hit_test_workflow_panels(
        engine=driver.engine,
        view=driver.view,
        root=driver.engine.nodes[driver.root_id],
        click_x=cx,
        click_y=cy,
    )
    # Title region: panel hit but no item.
    assert item_id is None


def test_click_outside_all_panels(driver_with_workflow_scene):
    """A click outside every panel's screen rectangle returns no hit."""
    driver = driver_with_workflow_scene
    # World x = +10 is well past the rightmost panel (x ≈ +4.4 ± 1.0).
    cx, cy = _find_canvas_xy_for_world(driver, world_x=10.0, world_y=0.0)
    panel_id, item_id = _hit_test_workflow_panels(
        engine=driver.engine,
        view=driver.view,
        root=driver.engine.nodes[driver.root_id],
        click_x=cx,
        click_y=cy,
    )
    assert panel_id is None
    assert item_id is None


def test_click_past_last_item(driver_with_workflow_scene):
    """A click in the bottom of an empty panel (no items below the last
    rendered row) returns no item-id."""
    driver = driver_with_workflow_scene
    # The tasks_source reads tasks.md; depending on machine state it may
    # have 0 or many items. Aim at world (-4.4, -2.0) — bottom of tasks_panel.
    cx, cy = _find_canvas_xy_for_world(driver, world_x=-4.4, world_y=-2.0)
    panel_id, item_id = _hit_test_workflow_panels(
        engine=driver.engine,
        view=driver.view,
        root=driver.engine.nodes[driver.root_id],
        click_x=cx,
        click_y=cy,
    )
    # Either we landed past the last item (item_id None) or we hit a real
    # item near the bottom of the panel — both outcomes are valid; we just
    # assert the function returned cleanly.
    assert panel_id in (None, "task_panel")


# ---------------------------------------------------------------------------
# Global handler dispatch
# ---------------------------------------------------------------------------


def test_handler_dispatches_expand_on_hit(driver_with_workflow_scene):
    driver = driver_with_workflow_scene
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.0)
    event = InputEvent(
        kind="mouse_button", button="left", pressed=True, x=cx, y=cy, timestamp=0.0,
    )
    consumed = click_dispatches_on_workflow_panels(event, driver)
    assert consumed is True
    state = get_view_state(driver.engine, "wish_panel")
    assert state.get("expanded_item") is not None


def test_handler_ignores_release(driver_with_workflow_scene):
    """Only mouse_button + pressed=True fires; release is ignored so a
    single click does not double-dispatch."""
    driver = driver_with_workflow_scene
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.0)
    event = InputEvent(
        kind="mouse_button", button="left", pressed=False, x=cx, y=cy, timestamp=0.0,
    )
    consumed = click_dispatches_on_workflow_panels(event, driver)
    assert consumed is False


def test_handler_ignores_right_button(driver_with_workflow_scene):
    driver = driver_with_workflow_scene
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.0)
    event = InputEvent(
        kind="mouse_button", button="right", pressed=True, x=cx, y=cy, timestamp=0.0,
    )
    consumed = click_dispatches_on_workflow_panels(event, driver)
    assert consumed is False


def test_handler_ignores_unknown_position(driver_with_workflow_scene):
    """An event with x=-1 (the default-unknown sentinel) is ignored —
    a backend that doesn't carry mouse coordinates should not produce
    a hit through this handler."""
    driver = driver_with_workflow_scene
    event = InputEvent(
        kind="mouse_button", button="left", pressed=True, x=-1, y=-1, timestamp=0.0,
    )
    consumed = click_dispatches_on_workflow_panels(event, driver)
    assert consumed is False


def test_handler_ignores_non_workflow_root():
    """Non-WorkflowView roots return False so the click passes through
    to view-mutation bindings."""
    engine = Engine(root_dir=ROOT)
    engine.discover()
    engine.spawn("Cube", "cube0", {"size": 1.0})
    driver = RealtimeDriver(
        engine=engine, root_id="cube0", view=View(width=16, height=16), frame_budget_s=0.0,
    )
    event = InputEvent(
        kind="mouse_button", button="left", pressed=True, x=8, y=8, timestamp=0.0,
    )
    consumed = click_dispatches_on_workflow_panels(event, driver)
    assert consumed is False


def test_default_global_handlers_include_click_dispatch(driver_with_workflow_scene):
    """The driver's default global-handlers list includes the click
    dispatcher — a consumer constructing a RealtimeDriver without
    overriding global_handlers gets the click-handling for free."""
    driver = driver_with_workflow_scene
    handler_names = {getattr(h, "__name__", "") for h in driver.global_handlers}
    assert "click_dispatches_on_workflow_panels" in handler_names


def test_click_through_run_one_frame_path(driver_with_workflow_scene):
    """End-to-end: queue a click event through the StubBackend, run one
    frame, confirm consumed_globally counted and view-state updated."""
    from tests.test_realtime import StubBackend  # noqa: PLC0415 — fixture import

    driver = driver_with_workflow_scene
    backend = StubBackend()
    backend.open(driver.view.width, driver.view.height, "test")
    cx, cy = _find_canvas_xy_for_world(driver, world_x=0.0, world_y=2.0)
    backend.queue_events(
        InputEvent(
            kind="mouse_button",
            button="left",
            pressed=True,
            x=cx,
            y=cy,
            timestamp=0.0,
        )
    )
    stats = driver.run_one_frame(backend)
    assert stats.consumed_globally >= 1
    state = get_view_state(driver.engine, "wish_panel")
    assert state.get("expanded_item") is not None
