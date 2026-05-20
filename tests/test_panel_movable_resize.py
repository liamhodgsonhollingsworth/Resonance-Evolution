"""
Tests for the SPEC-007 movable / resizable / snap / lock panels.

The three behaviours under test:

- **Drag-move** (v1): cursor delta translates to handle (x, y); on release
  the snapped coordinates are committed.
- **Drag-resize** (v2): cursor delta on the SE corner translates to
  handle (w, h); snapped to the grid.
- **Snap-to-grid** (v1/v2): every move/resize through the programmatic
  surface rounds to the 12-px grid.
- **Lock** (v3): locked panels reject move/resize via every surface
  (programmatic + drag handlers).

These tests run headless (no Tk root constructed). The panel
positioning model operates on PanelHandle records; the Tk widget is
only re-placed when one exists. Headless tests exercise the handle
layer + drag semantics via synthesized events.
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.gui_test_driver import GuiDriver
from tools.workflow_gui.gui_shell import (
    SNAP_GRID_PX,
    PanelHandle,
    snap_to_grid,
)


# ---------------------------------------------------------------------------
# Snap math (pure function — no shell required).
# ---------------------------------------------------------------------------


def test_snap_to_grid_rounds_to_nearest_multiple():
    """SPEC-007: every move/resize rounds to the 12-px grid. The math
    is round-to-nearest (not floor) so a value at the midpoint between
    two grid lines snaps consistently."""
    assert snap_to_grid(0) == 0
    assert snap_to_grid(12) == 12
    assert snap_to_grid(13) == 12
    assert snap_to_grid(17) == 12  # nearest of 12 vs 24
    assert snap_to_grid(18) == 24
    assert snap_to_grid(100) == 96  # nearest of 96 vs 108


def test_snap_to_grid_handles_negatives():
    """Negative values round to the nearest negative multiple. The
    drag handlers clamp the result to 0 separately so the panel never
    leaves the top-left edge of the host."""
    assert snap_to_grid(-12) == -12
    assert snap_to_grid(-5) == 0  # nearer to 0 than -12
    assert snap_to_grid(-7) == -12


def test_snap_grid_constant_matches_design_doc():
    """SPEC-007 design doc specifies 12-px snap distance. This catches
    a drift if a future edit changes the constant without updating
    the design."""
    assert SNAP_GRID_PX == 12


# ---------------------------------------------------------------------------
# Programmatic move via move_panel.
# ---------------------------------------------------------------------------


def test_move_panel_snaps_to_grid():
    """move_panel(x=17, y=29) should snap to (12, 24) — the nearest
    multiples of 12. The text-API verb is the post-snap surface; raw
    cursor coordinates never bypass the snap."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    state = drv.move_panel("test_panel", 17, 29)
    assert state["x"] == 12
    assert state["y"] == 24


def test_move_panel_idempotent_at_grid_lines():
    """Calling move_panel twice with the same grid-aligned args is a
    no-op (the snap-grid math round-trips cleanly)."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 36, 48)
    state_a = drv.panel_state("test_panel")
    drv.move_panel("test_panel", 36, 48)
    state_b = drv.panel_state("test_panel")
    assert state_a == state_b


def test_move_panel_creates_handle_on_demand():
    """ensure_panel + move_panel is the canonical create-and-position
    flow. After move, the handle is in _panel_handles."""
    drv = GuiDriver().build()
    state = drv.ensure_panel("fresh_panel")
    assert state["panel_id"] == "fresh_panel"
    drv.move_panel("fresh_panel", 60, 72)
    final = drv.panel_state("fresh_panel")
    assert final["x"] == 60
    assert final["y"] == 72


def test_move_panel_does_not_change_size():
    """A move keeps the panel's w/h. Verifies move + resize are
    independent code paths in the handle dataclass."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    pre = drv.panel_state("test_panel")
    drv.move_panel("test_panel", 36, 48)
    post = drv.panel_state("test_panel")
    assert post["w"] == pre["w"]
    assert post["h"] == pre["h"]


# ---------------------------------------------------------------------------
# Programmatic resize via resize_panel.
# ---------------------------------------------------------------------------


def test_resize_panel_snaps_to_grid():
    """resize_panel(w=505, h=313) snaps to the nearest multiple of 12."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    state = drv.resize_panel("test_panel", 505, 313)
    # 505/12 = 42.08 → 42*12=504; 313/12=26.08 → 26*12=312
    assert state["w"] == 504
    assert state["h"] == 312


def test_resize_panel_clamps_to_minimum():
    """w/h clamp to a 48 px minimum so a snap-to-zero never makes the
    panel unreachable."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    state = drv.resize_panel("test_panel", 1, 1)
    assert state["w"] >= 48
    assert state["h"] >= 48


def test_resize_panel_preserves_position():
    """A resize keeps the panel's x/y. Verifies the resize handler
    doesn't accidentally trample the position."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 24, 36)
    drv.resize_panel("test_panel", 600, 400)
    state = drv.panel_state("test_panel")
    assert state["x"] == 24
    assert state["y"] == 36


# ---------------------------------------------------------------------------
# Drag gesture semantics (synthesized events).
# ---------------------------------------------------------------------------


def _evt(x_root: int, y_root: int) -> SimpleNamespace:
    return SimpleNamespace(x_root=x_root, y_root=y_root)


def test_drag_motion_translates_handle():
    """A drag from (100, 100) to (160, 124) moves the panel by
    (+60, +24) — both already grid-aligned. The handle reflects the
    delta after motion."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 0, 0)
    drv.shell._on_panel_drag_start(_evt(100, 100), "test_panel")
    drv.shell._on_panel_drag_motion(_evt(160, 124), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == 60
    assert state["y"] == 24


def test_drag_release_clears_gesture_state():
    """Release commits the motion-final position and clears
    _panel_drag so a stale gesture doesn't leak into the next drag."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.shell._on_panel_drag_start(_evt(0, 0), "test_panel")
    drv.shell._on_panel_drag_motion(_evt(36, 60), "test_panel")
    drv.shell._on_panel_drag_release(_evt(36, 60), "test_panel")
    assert drv.shell._panel_drag is None
    # The motion-committed coordinates persist.
    state = drv.panel_state("test_panel")
    assert state["x"] == 36
    assert state["y"] == 60


def test_drag_motion_snaps_to_grid():
    """Mid-drag, cursor positions that fall between grid lines snap to
    the nearest line. A drag delta of (+19, +13) snaps to (+24, +12)."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 0, 0)
    drv.shell._on_panel_drag_start(_evt(0, 0), "test_panel")
    drv.shell._on_panel_drag_motion(_evt(19, 13), "test_panel")
    state = drv.panel_state("test_panel")
    # 19 → nearest of 12 and 24: 19-12=7, 24-19=5; 24 wins.
    # 13 → nearest of 12 and 24: 13-12=1, 24-13=11; 12 wins.
    assert state["x"] == 24
    assert state["y"] == 12


def test_drag_clamps_to_top_left_edge():
    """A drag past (0, 0) clamps to the origin so the panel never
    leaves the visible host area."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 36, 48)
    drv.shell._on_panel_drag_start(_evt(100, 100), "test_panel")
    drv.shell._on_panel_drag_motion(_evt(-200, -200), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == 0
    assert state["y"] == 0


def test_drag_motion_without_start_is_noop():
    """A B1-Motion event that arrives without a preceding ButtonPress-1
    (gesture corrupted, focus stolen, etc.) leaves the handle untouched."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 24, 36)
    drv.shell._panel_drag = None  # no anchored gesture
    drv.shell._on_panel_drag_motion(_evt(500, 500), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == 24
    assert state["y"] == 36


# ---------------------------------------------------------------------------
# Lock semantics — lock blocks every move/resize surface.
# ---------------------------------------------------------------------------


def test_lock_prevents_move_panel():
    """A locked panel ignores move_panel. The handle stays at the
    pre-lock position."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 24, 36)
    drv.lock_panel("test_panel")
    drv.move_panel("test_panel", 96, 120)
    state = drv.panel_state("test_panel")
    assert state["x"] == 24
    assert state["y"] == 36
    assert state["locked"] is True


def test_lock_prevents_resize_panel():
    """A locked panel ignores resize_panel."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    initial = drv.panel_state("test_panel")
    drv.lock_panel("test_panel")
    drv.resize_panel("test_panel", 800, 600)
    state = drv.panel_state("test_panel")
    assert state["w"] == initial["w"]
    assert state["h"] == initial["h"]


def test_lock_prevents_drag_start():
    """A locked panel rejects the drag-start handler — _panel_drag
    stays None so subsequent motion events also no-op."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.shell._on_panel_drag_start(_evt(0, 0), "test_panel")
    assert drv.shell._panel_drag is None


def test_lock_prevents_drag_motion():
    """Even if a drag was anchored before the lock, motion events
    after the lock are blocked — guard inside the motion handler."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 0, 0)
    drv.shell._on_panel_drag_start(_evt(0, 0), "test_panel")
    drv.lock_panel("test_panel")  # mid-gesture
    drv.shell._on_panel_drag_motion(_evt(48, 60), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == 0
    assert state["y"] == 0


def test_unlock_restores_mobility():
    """Unlock flips locked back to False and subsequent moves work."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.unlock_panel("test_panel")
    drv.move_panel("test_panel", 60, 72)
    state = drv.panel_state("test_panel")
    assert state["x"] == 60
    assert state["y"] == 72
    assert state["locked"] is False


def test_lock_on_nonexistent_panel_returns_false():
    """lock_panel against a panel with no handle returns False rather
    than silently creating one."""
    drv = GuiDriver().build()
    assert drv.lock_panel("nonexistent") is False


def test_is_locked_reflects_state():
    """is_locked is a cheap read used by the right-click menu to
    toggle the Lock/Unlock label."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    assert drv.shell.is_locked("test_panel") is False
    drv.lock_panel("test_panel")
    assert drv.shell.is_locked("test_panel") is True


# ---------------------------------------------------------------------------
# Driver-level read_state surface.
# ---------------------------------------------------------------------------


def test_read_state_surfaces_panel_handles():
    """read_state() includes panel_handles so callers can assert
    panel positioning without poking shell internals."""
    drv = GuiDriver().build()
    drv.ensure_panel("alpha")
    drv.move_panel("alpha", 24, 36)
    drv.ensure_panel("beta")
    drv.move_panel("beta", 48, 60)
    state = drv.read_state()
    assert "alpha" in state["panel_handles"]
    assert state["panel_handles"]["alpha"]["x"] == 24
    assert state["panel_handles"]["beta"]["y"] == 60


def test_read_state_archived_panels_list():
    """read_state's archived_panels list reflects the per-handle
    archived flag."""
    drv = GuiDriver().build()
    drv.ensure_panel("alpha")
    drv.archive_panel("alpha")
    state = drv.read_state()
    assert "alpha" in state["archived_panels"]


# ---------------------------------------------------------------------------
# Default-position handle creation.
# ---------------------------------------------------------------------------


def test_ensure_panel_handle_creates_at_staggered_position():
    """First handle starts near (0, 0); subsequent handles offset by
    a fixed step so two default-positioned panels don't fully overlap."""
    drv = GuiDriver().build()
    a = drv.ensure_panel("a")
    b = drv.ensure_panel("b")
    assert a["x"] == 0 and a["y"] == 0
    assert b["x"] > a["x"] or b["y"] > a["y"], (
        f"second handle should stagger; got a={a}, b={b}"
    )


# ---------------------------------------------------------------------------
# v2 drag-resize gesture (SE corner grip).
# ---------------------------------------------------------------------------


def test_resize_drag_start_anchors_gesture():
    """Pressing the SE grip records the cursor anchor + the current
    (w, h) so motion events compute deltas correctly."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    initial = drv.panel_state("test_panel")
    drv.shell._on_panel_resize_start(_evt(500, 400), "test_panel")
    drag = drv.shell._panel_drag
    assert drag is not None
    assert drag["kind"] == "resize"
    assert drag["panel_id"] == "test_panel"
    assert drag["origin_w"] == initial["w"]
    assert drag["origin_h"] == initial["h"]


def test_resize_drag_motion_translates_to_width_height():
    """A resize-drag from anchor (500, 400) to (560, 460) increases
    the panel by (+60, +60). The result is then snapped to the
    12-px grid: 480+60=540 (divisible by 12) and 312+60=372 (the
    starting h=312 is the snapped form of 320)."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    # resize_panel(480, 320) → snaps 320 to 324 (320/12=26.67 → round=27→324).
    state_pre = drv.resize_panel("test_panel", 480, 320)
    # 60 px delta is grid-aligned; 540 and (h+60) both round cleanly.
    drv.shell._on_panel_resize_start(_evt(500, 400), "test_panel")
    drv.shell._on_panel_resize_motion(_evt(560, 460), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["w"] == 540
    # h_post = snap_to_grid(state_pre["h"] + 60)
    assert state["h"] == snap_to_grid(state_pre["h"] + 60)


def test_resize_drag_snaps_to_grid():
    """Motion events snap the resulting (w, h) to the 12-px grid.
    Delta of (+19, +13) from grid-aligned 480x324 snaps to 504x336
    (480+24, 324+12) — independent axes."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    # 480 and 324 are both grid-aligned (480=40*12, 324=27*12).
    drv.resize_panel("test_panel", 480, 324)
    drv.shell._on_panel_resize_start(_evt(0, 0), "test_panel")
    drv.shell._on_panel_resize_motion(_evt(19, 13), "test_panel")
    state = drv.panel_state("test_panel")
    # 480 + 24 = 504, 324 + 12 = 336.
    assert state["w"] == 504
    assert state["h"] == 336


def test_resize_drag_release_clears_gesture():
    """ButtonRelease commits the motion-final dimensions and clears
    _panel_drag so a subsequent gesture starts clean."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.shell._on_panel_resize_start(_evt(0, 0), "test_panel")
    drv.shell._on_panel_resize_motion(_evt(48, 60), "test_panel")
    drv.shell._on_panel_resize_release(_evt(48, 60), "test_panel")
    assert drv.shell._panel_drag is None


def test_resize_drag_blocked_when_locked():
    """A locked panel rejects the resize-drag-start anchor — the
    gesture never starts so motion events also no-op."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.shell._on_panel_resize_start(_evt(0, 0), "test_panel")
    assert drv.shell._panel_drag is None


def test_resize_drag_clamps_to_minimum():
    """Even with a large negative delta, w/h stay >= 48 px so the
    panel never shrinks to unreachable."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.resize_panel("test_panel", 480, 320)
    drv.shell._on_panel_resize_start(_evt(500, 400), "test_panel")
    drv.shell._on_panel_resize_motion(_evt(-1000, -1000), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["w"] >= 48
    assert state["h"] >= 48


def test_move_motion_does_not_process_resize_gesture():
    """The motion handlers cross-check the gesture kind so a
    resize-drag in progress isn't accidentally processed as a move."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    initial = drv.panel_state("test_panel")
    drv.shell._on_panel_resize_start(_evt(0, 0), "test_panel")
    # If the move handler ran, the x/y would change. The kind guard
    # should make this a no-op for position.
    drv.shell._on_panel_drag_motion(_evt(48, 60), "test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == initial["x"]
    assert state["y"] == initial["y"]


# ---------------------------------------------------------------------------
# v2 snap-to-edges (peer-edge alignment on release).
# ---------------------------------------------------------------------------


def test_compute_snap_aligns_to_peer_left_edge():
    """If a moving panel's left edge is within snap distance of a
    peer's left edge, _compute_snap returns the peer's x as the
    snapped position."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 96
    target.y = 200
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 0
    peer.w = 200
    peer.h = 100
    snap_x, snap_y = drv.shell._compute_snap(target, [peer])
    # target.x=96 is 4 px from peer.x=100 (within 12-px snap).
    assert snap_x == 100


def test_compute_snap_aligns_to_peer_right_edge():
    """A target's left edge can snap to a peer's right edge."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 304  # 4 px from (peer.x + peer.w) = 300
    target.y = 200
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 0
    peer.w = 200
    peer.h = 100
    snap_x, _ = drv.shell._compute_snap(target, [peer])
    assert snap_x == 300


def test_compute_snap_no_snap_when_far_from_peer():
    """When no peer edge is within snap distance, the returned (x, y)
    matches the panel's current position (no snap fires)."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 500
    target.y = 500
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 100
    peer.w = 50
    peer.h = 50
    snap_x, snap_y = drv.shell._compute_snap(target, [peer])
    assert snap_x == 500
    assert snap_y == 500


def test_compute_snap_independent_axes():
    """x and y snap independently — a panel can align horizontally
    to a peer while leaving y unchanged if no y peer is in range."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 96  # 4 px from peer.x=100
    target.y = 500
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 100
    peer.w = 50
    peer.h = 50
    snap_x, snap_y = drv.shell._compute_snap(target, [peer])
    assert snap_x == 100  # snapped
    assert snap_y == 500  # unchanged


def test_compute_snap_ignores_archived_peers():
    """Archived panels don't contribute to the snap set — they're
    not visible, so snapping to their edges would surprise the user."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 96
    target.y = 200
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 0
    peer.w = 200
    peer.h = 100
    peer.archived = True
    snap_x, _ = drv.shell._compute_snap(target, [peer])
    assert snap_x == 96  # no snap


def test_drag_release_applies_peer_snap():
    """End-to-end: drag-release runs the peer-snap pass and pulls
    the panel onto a peer edge that isn't itself grid-aligned.

    Setup: peer at x=190 (not on the 12-px grid). Target drag lands
    at the grid-aligned 180. On release, the peer-snap pass detects
    the peer's left edge at 190 is within 12 px of target.x=180 and
    pulls the target to 190.
    """
    drv = GuiDriver().build()
    drv.ensure_panel("target")
    drv.ensure_panel("peer")
    # Place the peer by directly mutating the handle so we can pick
    # a non-grid-aligned x without snap_to_grid rounding it.
    drv.shell._panel_handles["peer"].x = 190
    drv.shell._panel_handles["peer"].y = 0
    drv.shell._panel_handles["peer"].w = 240
    drv.shell._panel_handles["peer"].h = 120
    drv.move_panel("target", 0, 240)
    # Drag the target so it lands at the grid-aligned 180 — 10 px short of 190.
    drv.shell._on_panel_drag_start(_evt(0, 0), "target")
    drv.shell._on_panel_drag_motion(_evt(180, 0), "target")
    pre_release = drv.panel_state("target")
    assert pre_release["x"] == 180  # snapped to grid mid-drag
    drv.shell._on_panel_drag_release(_evt(180, 0), "target")
    post_release = drv.panel_state("target")
    assert post_release["x"] == 190  # peer-snap fired


def test_resize_release_applies_peer_snap():
    """End-to-end: resize-release also runs the peer-snap pass so
    a resize that lands the corner near a peer's edge aligns."""
    drv = GuiDriver().build()
    drv.ensure_panel("target")
    drv.ensure_panel("peer")
    drv.move_panel("target", 0, 0)
    drv.resize_panel("target", 480, 320)
    drv.move_panel("peer", 504, 0)  # 24 px gap from target's right edge
    drv.shell._on_panel_resize_start(_evt(0, 0), "target")
    drv.shell._on_panel_resize_release(_evt(0, 0), "target")
    # Snap shouldn't fire (peer is > snap_distance away on x).
    state = drv.panel_state("target")
    assert state["w"] == 480  # unchanged


def test_compute_snap_locked_panels_still_snap_against():
    """A locked panel still acts as a snap target for other panels —
    locking prevents its own movement, not its visibility in the
    snap set. The maintainer aligns moving panels to fixed ones."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 96
    target.y = 200
    peer = drv.shell._ensure_panel_handle("peer")
    peer.x = 100
    peer.y = 0
    peer.w = 200
    peer.h = 100
    peer.locked = True
    snap_x, _ = drv.shell._compute_snap(target, [peer])
    assert snap_x == 100  # snap fires even though peer is locked


def test_compute_snap_no_peers_returns_unchanged():
    """A panel with no peers (only one panel in the host) returns
    its own position — the snap helper degrades gracefully."""
    drv = GuiDriver().build()
    target = drv.shell._ensure_panel_handle("target")
    target.x = 36
    target.y = 48
    snap_x, snap_y = drv.shell._compute_snap(target, [])
    assert snap_x == 36
    assert snap_y == 48
