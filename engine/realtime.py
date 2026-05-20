"""
Realtime renderer driver — backend-agnostic interactive event loop.

Wraps a windowing backend with the engine's ``assemble`` + ``Bindings`` +
``ViewMutation`` pipeline so any scene becomes interactive: the maintainer
moves the camera with WASD + mouse, the engine assembles the scene each
frame, the backend blits the resulting color channel to the window.

Backends implement the ``WindowBackend`` protocol below. The default
backend is :mod:`engine.realtime_tk` — pure stdlib via tkinter, no external
deps. A pygame backend will follow when dream-mode mouse-look needs
pointer-lock; the protocol is shared.

Headless-testable: pass a stub backend with canned events and inspect the
driver's view + channels after each frame. Real Tk is never required to
test the driver's logic.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Protocol, Tuple

import numpy as np

from engine.input import (
    Bindings,
    BindingContext,
    InputEvent,
    ViewMutation,
    apply_mutation,
)
from engine.node import View


# ---------------------------------------------------------------------------
# Backend protocol.
# ---------------------------------------------------------------------------


class WindowBackend(Protocol):
    """The realtime driver talks to a window via this surface.

    Methods are called in this order: ``open`` once, then a loop of
    ``poll_events`` / ``blit_color`` / ``should_close`` (any order each
    frame), then ``close`` once at teardown. ``set_title`` and
    ``set_fullscreen`` are optional — call when a frame's metadata
    changes or the driver wants to toggle fullscreen.

    Backends that can't fulfill ``set_fullscreen`` should accept the
    call as a no-op rather than raise — the driver's F11 handler is
    best-effort.
    """

    def open(self, width: int, height: int, title: str = "Apeiron") -> None: ...
    def poll_events(self) -> List[InputEvent]: ...
    def blit_color(self, color_array: np.ndarray) -> None: ...
    def should_close(self) -> bool: ...
    def close(self) -> None: ...
    def set_title(self, title: str) -> None: ...
    def set_fullscreen(self, fullscreen: bool) -> None: ...
    def is_fullscreen(self) -> bool: ...


# ---------------------------------------------------------------------------
# Global key handler — non-view actions (escape, fullscreen, mode toggle, etc.)
# ---------------------------------------------------------------------------


GlobalHandler = Callable[[InputEvent, "RealtimeDriver"], bool]


def f11_toggles_fullscreen(
    event: InputEvent, driver: "RealtimeDriver"
) -> bool:
    """F11 key handler: toggles the backend's fullscreen state.

    The driver caches the backend reference on its first ``run_one_frame``
    so handlers can ask the backend to toggle without the driver needing
    to receive the backend as an argument to every step. Best-effort —
    backends that can't fulfill fullscreen accept the call as a no-op.
    """
    if event.kind != "key_down" or event.key != "f11":
        return False
    backend = driver._current_backend
    if backend is None:
        return True
    try:
        currently = backend.is_fullscreen()
        backend.set_fullscreen(not currently)
    except Exception as e:
        driver.engine.errors.append(f"realtime: fullscreen toggle failed: {e}")
    return True


def click_dispatches_on_workflow_panels(
    event: InputEvent, driver: "RealtimeDriver"
) -> bool:
    """Left-click on a WorkflowView panel dispatches ``expand`` against the
    clicked item-row.

    The compositor positions each panel via the WorkflowView's
    connection transform; this handler reverses that transform to
    intersect the click ray with the panel's local screen rectangle,
    converts the hit position to bitmap UV, and uses the renderer's
    item-row layout to pick the item-id. ``engine.actions.dispatch_action``
    is then invoked with ``expand`` and the resolved id.

    Returns True only if a panel item was actually hit; non-hits return
    False so mouse-button bindings (camera interaction) still fire on
    non-panel clicks.

    Only handles left-button press on a ``WorkflowView`` root. Other
    root types return False — the event passes through unchanged.
    Right-clicks and middle-clicks are also passed through; future
    work can extend this with context-menu actions.
    """
    if event.kind != "mouse_button" or event.button != "left" or not event.pressed:
        return False
    if event.x < 0 or event.y < 0:
        return False
    engine = driver.engine
    root = engine.nodes.get(driver.root_id)
    if root is None or root.type_name != "WorkflowView":
        return False
    panel_id, item_id = _hit_test_workflow_panels(
        engine=engine,
        view=driver.view,
        root=root,
        click_x=event.x,
        click_y=event.y,
    )
    if panel_id is None or item_id is None:
        return False
    from engine.actions import dispatch_action

    try:
        dispatch_action(engine, panel_id, "expand", item_id=item_id)
    except Exception as e:
        engine.errors.append(f"realtime click dispatch: {e}")
    return True


def _hit_test_workflow_panels(
    *,
    engine: Any,
    view: View,
    root,
    click_x: int,
    click_y: int,
) -> Tuple[Optional[str], Optional[str]]:
    """Return ``(panel_id, item_id)`` for the panel item hit by a click at
    canvas pixel ``(click_x, click_y)``, or ``(None, None)`` if no panel
    item was hit.

    The click is cast as a ray from the camera through the canvas pixel,
    then transformed into each panel's local frame (reversing the
    WorkflowView connection transform). A hit on z=0 within the panel's
    ``screen_width`` × ``screen_height`` rectangle counts; the hit's UV
    coordinates are then mapped to the panel's bitmap-pixel layout to
    pick which item-row was clicked. The title region (above the
    horizontal divider) returns no item.
    """
    canvas_w = max(1, int(getattr(view, "width", 0) or 1))
    canvas_h = max(1, int(getattr(view, "height", 0) or 1))
    aspect = canvas_w / canvas_h if canvas_h > 0 else 1.0
    half_h = float(np.tan(view.fov_y_radians / 2.0))
    half_w = half_h * aspect
    u = (click_x / canvas_w) * 2.0 - 1.0
    v = 1.0 - (click_y / canvas_h) * 2.0
    dir_cam = np.array([u * half_w, v * half_h, -1.0], dtype=np.float64)
    dir_cam /= np.linalg.norm(dir_cam)
    dir_world = view.orientation @ dir_cam
    origin_world = np.asarray(view.position, dtype=np.float64)

    for conn_name, conn in root.connections.items():
        if not conn_name.startswith("panel_"):
            continue
        target_id, transform = _resolve_panel_connection(conn)
        if target_id is None:
            continue
        target_node = engine.nodes.get(target_id)
        if target_node is None or target_node.type_name != "ListRenderer":
            continue
        # Transform ray into panel-local frame.
        if transform is None:
            local_origin = origin_world
            local_dir = dir_world
        else:
            R = np.asarray(transform[:3, :3], dtype=np.float64)
            t = np.asarray(transform[:3, 3], dtype=np.float64)
            local_origin = R.T @ (origin_world - t)
            local_dir = R.T @ dir_world
        if abs(local_dir[2]) < 1e-9:
            continue
        ray_t = -local_origin[2] / local_dir[2]
        if ray_t <= 0:
            continue
        hit_x = local_origin[0] + ray_t * local_dir[0]
        hit_y = local_origin[1] + ray_t * local_dir[1]
        state = target_node.state or {}
        screen_w = float(state.get("screen_width", 3.0))
        screen_h = float(state.get("screen_height", 4.0))
        if abs(hit_x) > screen_w / 2.0 or abs(hit_y) > screen_h / 2.0:
            continue
        item_id = _panel_row_to_item_id(
            engine=engine,
            panel_node=target_node,
            hit_x=hit_x,
            hit_y=hit_y,
            screen_w=screen_w,
            screen_h=screen_h,
        )
        if item_id is not None:
            return target_id, item_id
    return None, None


def _resolve_panel_connection(conn) -> Tuple[Optional[str], Optional[np.ndarray]]:
    """Mirror of ``Engine._resolve_connection`` for the click-handler so we
    do not import from engine.core (avoids circular imports)."""
    if isinstance(conn, str):
        return conn, None
    if isinstance(conn, dict):
        tf = conn.get("transform")
        if tf is not None:
            tf = np.asarray(tf, dtype=np.float64)
        return conn.get("target"), tf
    if isinstance(conn, list) and conn:
        target_id = conn[0]
        tf = np.asarray(conn[1], dtype=np.float64) if len(conn) > 1 else None
        return target_id, tf
    return None, None


def _panel_row_to_item_id(
    *,
    engine: Any,
    panel_node,
    hit_x: float,
    hit_y: float,
    screen_w: float,
    screen_h: float,
) -> Optional[str]:
    """Map a hit position inside a panel's screen rectangle to the
    item-id of the item-row underneath that hit.

    Returns ``None`` when the hit lands in the title/header strip, in an
    empty row past the last item, or when the panel has no source data.
    """
    # UV in the panel's local 2D frame (0..1, top-left origin).
    panel_u = (hit_x + screen_w / 2.0) / screen_w
    panel_v = 1.0 - (hit_y + screen_h / 2.0) / screen_h
    state = panel_node.state or {}
    res_max = int(state.get("screen_resolution", 384))
    font_size = int(state.get("font_size", 14))
    aspect = screen_w / screen_h if screen_h > 0 else 1.0
    if aspect >= 1.0:
        screen_w_px = res_max
        screen_h_px = max(1, int(round(res_max / aspect)))
    else:
        screen_h_px = res_max
        screen_w_px = max(1, int(round(res_max * aspect)))
    bitmap_y = panel_v * screen_h_px
    margin = max(4, font_size // 3)
    header_end_y = margin + int(font_size * 1.6)
    if bitmap_y < header_end_y:
        return None
    line_h = font_size + 4
    relative_y = bitmap_y - header_end_y
    row_index = int(relative_y // line_h)
    if row_index < 0:
        return None
    # Look up the panel's source items.
    conn = panel_node.connections.get("source") if hasattr(panel_node, "connections") else None
    if conn is None:
        return None
    if isinstance(conn, str):
        source_id = conn
    elif isinstance(conn, dict):
        source_id = conn.get("target")
    elif isinstance(conn, list) and conn:
        source_id = conn[0]
    else:
        return None
    if not source_id:
        return None
    cache_entry = engine.cache.get(source_id, {})
    if not isinstance(cache_entry, dict):
        return None
    items = cache_entry.get("items") or []
    scroll_offset = int(state.get("scroll_offset", 0))
    target_index = scroll_offset + row_index
    if target_index < 0 or target_index >= len(items):
        return None
    return items[target_index].get("id")


def escape_toggles_workflow_mode_or_quits(
    event: InputEvent, driver: "RealtimeDriver"
) -> bool:
    """Escape key handler.

    If the scene root is a WorkflowView, Escape toggles between
    ``"panels"`` and ``"full_render"`` modes (wishlist #010 + SPEC-011).
    Otherwise Escape signals the driver to quit. Either case consumes the
    event.
    """
    if event.kind != "key_down" or event.key != "escape":
        return False
    root = driver.engine.nodes.get(driver.root_id)
    if root is not None and root.type_name == "WorkflowView":
        current = (root.state or {}).get("mode", "panels")
        new_mode = "full_render" if current == "panels" else "panels"
        try:
            module = driver.engine.types.get("WorkflowView")
            if module is not None and hasattr(module, "set_mode"):
                module.set_mode(root, new_mode)
            else:
                root.state["mode"] = new_mode
        except Exception:
            driver.engine.errors.append(
                f"realtime: escape mode-toggle failed for {driver.root_id!r}"
            )
        return True
    driver.request_quit()
    return True


# ---------------------------------------------------------------------------
# The driver.
# ---------------------------------------------------------------------------


@dataclass
class FrameStats:
    """One frame's accounting. Returned by ``run_one_frame`` for callers
    that want to inspect or display per-frame info."""

    frame_index: int = 0
    elapsed_s: float = 0.0
    event_count: int = 0
    mutation_count: int = 0
    consumed_globally: int = 0
    assemble_error: Optional[str] = None
    color_shape: Optional[Tuple[int, int, int]] = None


class RealtimeDriver:
    """Owns the per-frame loop wiring backend → bindings → engine → blit.

    The driver does not own the backend or the engine — both are injected.
    This keeps the driver pure logic (testable with stub backends) and
    lets the same driver shape support pygame, moderngl-window, or any
    future windowing layer.
    """

    def __init__(
        self,
        engine: Any,
        root_id: str,
        view: View,
        bindings: Optional[Bindings] = None,
        global_handlers: Optional[List[GlobalHandler]] = None,
        frame_budget_s: float = 1.0 / 60.0,
    ) -> None:
        self.engine = engine
        self.root_id = root_id
        self.view = view
        self.bindings = bindings if bindings is not None else Bindings.default()
        self.binding_context = BindingContext(current_view=self.view)
        self.global_handlers: List[GlobalHandler] = list(
            global_handlers
            if global_handlers is not None
            else (
                escape_toggles_workflow_mode_or_quits,
                f11_toggles_fullscreen,
                click_dispatches_on_workflow_panels,
            )
        )
        self.frame_budget_s = float(frame_budget_s)
        self.frame_index = 0
        self._quit_requested = False
        self._last_color: Optional[np.ndarray] = None
        # Set on each run_one_frame call so global handlers can reach the backend.
        self._current_backend: Optional[WindowBackend] = None

    # --- control ---

    def request_quit(self) -> None:
        self._quit_requested = True

    def should_quit(self, backend: WindowBackend) -> bool:
        return self._quit_requested or backend.should_close()

    def add_global_handler(self, handler: GlobalHandler) -> None:
        self.global_handlers.append(handler)

    # --- per-frame ---

    def process_event(self, event: InputEvent) -> Tuple[bool, List[ViewMutation]]:
        """Run global handlers; if none consume, resolve via bindings.

        Returns ``(consumed_globally, mutations)``. Public for tests.
        """
        for handler in self.global_handlers:
            try:
                if handler(event, self):
                    return True, []
            except Exception as e:
                self.engine.errors.append(f"realtime global handler: {e}")
                continue
        # Update the held-keys / last-press-time context BEFORE resolving
        # so handlers can read the post-event state.
        if event.kind == "key_down" and event.key is not None:
            self.binding_context.held_keys.add(event.key)
            self.binding_context.last_press_time[event.key] = event.timestamp
        elif event.kind == "key_up" and event.key is not None:
            self.binding_context.held_keys.discard(event.key)
        mutations = self.bindings.resolve(event, self.binding_context)
        return False, mutations

    def assemble_frame(self) -> Tuple[Optional[np.ndarray], Optional[str]]:
        """Call ``engine.assemble(root_id, view)`` and return the color
        channel + any error message. Errors don't raise — they return as
        the second element so the driver can keep running.
        """
        try:
            channels = self.engine.assemble(self.root_id, self.view)
        except Exception as e:
            return None, f"assemble: {e}"
        color = channels.get("color") if isinstance(channels, dict) else None
        if color is None:
            return None, "assemble: no color channel produced"
        return self._normalize_color(color), None

    @staticmethod
    def _normalize_color(color: Any) -> np.ndarray:
        """Coerce an emit-time color value to ``HxWx3`` uint8. Accepts:

        - ``HxWx3`` or ``HxWx4`` numpy arrays (uint8 or float in 0..1)
        - PIL Images (via ``np.asarray``)
        """
        arr = np.asarray(color)
        if arr.dtype != np.uint8:
            # Float in 0..1 → uint8 in 0..255.
            arr = np.clip(arr * 255.0, 0, 255).astype(np.uint8)
        if arr.ndim == 3 and arr.shape[2] == 4:
            arr = arr[:, :, :3]
        if arr.ndim != 3 or arr.shape[2] != 3:
            raise ValueError(
                f"color must be HxWx3; got shape={arr.shape} dtype={arr.dtype}"
            )
        return arr

    def run_one_frame(self, backend: WindowBackend) -> FrameStats:
        """Poll, resolve, mutate, assemble, blit. Returns FrameStats.

        Always blits something — if the assemble fails, a magenta-tinted
        version of the last good color frame is blitted so the
        maintainer sees a frame in distress is in distress (SPEC-030).
        If no previous frame exists, a 1-pixel magenta frame is blitted.
        """
        self._current_backend = backend
        t0 = time.perf_counter()
        events = backend.poll_events()
        consumed = 0
        mutations: List[ViewMutation] = []
        for event in events:
            was_consumed, ms = self.process_event(event)
            if was_consumed:
                consumed += 1
                continue
            mutations.extend(ms)
        for m in mutations:
            self.view = apply_mutation(self.view, m)
        self.binding_context.current_view = self.view

        color, err = self.assemble_frame()
        if color is None:
            if self._last_color is None:
                color = _solid_magenta(self.view.width, self.view.height)
            else:
                color = _magenta_tint(self._last_color)
        else:
            self._last_color = color
        try:
            backend.blit_color(color)
        except Exception as e:
            self.engine.errors.append(f"realtime blit: {e}")

        self.frame_index += 1
        return FrameStats(
            frame_index=self.frame_index,
            elapsed_s=time.perf_counter() - t0,
            event_count=len(events),
            mutation_count=len(mutations),
            consumed_globally=consumed,
            assemble_error=err,
            color_shape=tuple(color.shape),  # type: ignore[arg-type]
        )

    # --- the loop ---

    def run(self, backend: WindowBackend, max_frames: Optional[int] = None) -> int:
        """Run the loop until ``should_quit`` or ``max_frames`` is reached.

        Returns the number of frames rendered. ``max_frames`` is useful
        for headless testing — production calls pass ``None``.
        """
        rendered = 0
        try:
            while not self.should_quit(backend):
                self.run_one_frame(backend)
                rendered += 1
                if max_frames is not None and rendered >= max_frames:
                    break
                # Frame pacing: sleep the remainder of the frame budget.
                # Backends with their own vsync can pass frame_budget_s=0.
                if self.frame_budget_s > 0:
                    time.sleep(self.frame_budget_s)
        finally:
            try:
                backend.close()
            except Exception as e:
                self.engine.errors.append(f"realtime close: {e}")
        return rendered


# ---------------------------------------------------------------------------
# Placeholder helpers for the assemble-error fallback (SPEC-030).
# ---------------------------------------------------------------------------


_MAGENTA = np.array([255, 0, 255], dtype=np.uint8)


def _solid_magenta(width: int, height: int) -> np.ndarray:
    """Return an ``HxWx3`` solid-magenta frame for the no-prior-frame case."""
    out = np.empty((max(1, int(height)), max(1, int(width)), 3), dtype=np.uint8)
    out[:] = _MAGENTA
    return out


def _magenta_tint(color: np.ndarray) -> np.ndarray:
    """Half-blend the prior frame with magenta to mark distress while
    preserving recognizability of the last good frame's content."""
    arr = np.asarray(color)
    if arr.dtype != np.uint8 or arr.ndim != 3 or arr.shape[2] != 3:
        h = arr.shape[0] if arr.ndim >= 2 else 1
        w = arr.shape[1] if arr.ndim >= 2 else 1
        return _solid_magenta(w, h)
    blended = (arr.astype(np.uint16) + _MAGENTA.astype(np.uint16)) // 2
    return blended.astype(np.uint8)


# ---------------------------------------------------------------------------
# Backend discovery — pick the best available backend.
# ---------------------------------------------------------------------------


def available_backends() -> List[str]:
    """Return the names of installed backends, best-first."""
    found: List[str] = []
    try:
        import engine.realtime_tk  # noqa: F401

        found.append("tk")
    except Exception:
        pass
    return found


def make_backend(name: Optional[str] = None) -> WindowBackend:
    """Construct a backend by name; ``None`` picks the first available.

    Raises RuntimeError if the requested (or any) backend is unavailable.
    """
    if name is None:
        names = available_backends()
        if not names:
            raise RuntimeError(
                "no realtime backend available; install pygame or use a Python "
                "build with tkinter (the default stdlib)."
            )
        name = names[0]
    if name == "tk":
        from engine.realtime_tk import TkBackend

        return TkBackend()
    raise RuntimeError(f"unknown realtime backend: {name!r}")
