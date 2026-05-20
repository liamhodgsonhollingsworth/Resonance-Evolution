"""
Input system — bindable events that mutate a View.

Skeleton for the interactive (real-time) renderer's input pump. The realtime
renderer is not built yet (depends on a windowing-library choice deferred
to a future session). This module defines the types that downstream code —
interactive renderer, headless input simulation, KeyBindings node — all
work against, so the surface is stable before the windowing decision lands.

The principle from the architecture: input is one more sub-graph. An
InputEvent is parsed by a Bindings table into a ViewMutation that the
realtime renderer applies between frames. KeyBindings is a node-type whose
state IS a Bindings table; swapping the active KeyBindings node changes
the control scheme without engine changes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple
import numpy as np


# ---------------------------------------------------------------------------
# Event types — what an input source produces.
# ---------------------------------------------------------------------------


@dataclass
class InputEvent:
    """
    A single input event. Fields are optional; only those relevant to the
    kind populate. Extending the field set is non-breaking.

    kind:
      - "key_down" / "key_up"  → key populated (e.g. "w", "space", "t")
      - "mouse_move"           → dx, dy (relative deltas); x, y (canvas
                                  absolute position when known)
      - "mouse_button"         → button ("left"|"right"|"middle"), pressed
                                  (bool); x, y (canvas absolute position)
      - "scroll"               → dy populated (positive = away from user)
      - "text"                 → text populated (for chat input)

    ``x`` / ``y`` are integer canvas-space pixel coordinates (origin
    top-left, +y down). They default to ``-1`` to mean "unknown" so a
    backend that doesn't supply them (or a headless event with no mouse
    position) is distinguishable from a real (0, 0) corner click.
    """
    kind: str
    key: Optional[str] = None
    dx: float = 0.0
    dy: float = 0.0
    button: Optional[str] = None
    pressed: bool = False
    text: Optional[str] = None
    timestamp: float = 0.0
    x: int = -1
    y: int = -1


# ---------------------------------------------------------------------------
# Mutations — what binding-resolution produces. Applied to a View.
# ---------------------------------------------------------------------------


@dataclass
class ViewMutation:
    """
    A transform on a View. Applied by the realtime renderer between frames.
    Multiple ViewMutations from one event-batch compose by sequential apply.
    """
    delta_position: Optional[np.ndarray] = None     # local-frame offset
    delta_yaw: float = 0.0                          # rotation around gravity_up
    delta_pitch: float = 0.0                        # rotation around right-axis
    delta_roll: float = 0.0                         # rotation around forward-axis
    delta_scale: float = 0.0                        # additive on log-scale
    set_gravity_mode: Optional[str] = None          # "world"|"free"|...
    open_chat: bool = False
    text_to_send: Optional[str] = None
    custom: Dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Bindings — event-pattern → action mapping.
# ---------------------------------------------------------------------------


# A binding handler takes the matched event plus a small ambient state
# (held-keys, time-since-last-of-this-event, etc.) and returns a ViewMutation.
BindingHandler = Callable[[InputEvent, "BindingContext"], Optional[ViewMutation]]


@dataclass
class BindingContext:
    """
    Ambient state available to binding handlers. Filled by the realtime
    renderer between frames; the headless input simulator passes a stub.
    """
    held_keys: set = field(default_factory=set)
    last_press_time: Dict[str, float] = field(default_factory=dict)
    current_view: Optional[Any] = None  # forward ref: engine.node.View


@dataclass
class Bindings:
    """
    A pattern-to-handler map. Pattern matches happen kind-first then on
    key/button. The first matching handler wins; explicit ordering via
    `priority` (lower runs first) breaks ties.

    KeyBindings node-type wraps an instance of this class as its state.
    """
    table: List[Tuple[Dict[str, Any], BindingHandler, int]] = field(default_factory=list)
    move_speed: float = 4.0       # world units per second when WASD held
    look_sensitivity: float = 0.002
    scroll_zoom_factor: float = 0.1
    double_tap_window: float = 0.3  # seconds

    def add(self, pattern: Dict[str, Any], handler: BindingHandler, priority: int = 100) -> None:
        self.table.append((pattern, handler, priority))
        self.table.sort(key=lambda row: row[2])

    def resolve(self, event: InputEvent, ctx: BindingContext) -> List[ViewMutation]:
        """
        Try every pattern that matches event; return mutations in priority
        order. Multiple bindings on the same event are allowed (one event
        can both move and play a sound, for instance).
        """
        out: List[ViewMutation] = []
        for pattern, handler, _ in self.table:
            if _matches(pattern, event):
                try:
                    m = handler(event, ctx)
                except Exception:
                    continue
                if m is not None:
                    out.append(m)
        return out

    @classmethod
    def default(cls) -> "Bindings":
        """
        Minecraft-style default bindings. Returned as a fresh instance so
        callers may mutate freely. KeyBindings nodes can replace any entry.
        """
        b = cls()

        def _wasd(direction: np.ndarray):
            def handler(event: InputEvent, ctx: BindingContext) -> Optional[ViewMutation]:
                if event.kind != "key_down":
                    return None
                return ViewMutation(delta_position=direction * b.move_speed * 0.016)
            return handler

        # Local-frame: -Z forward, +X right, +Y up (matches View orientation columns)
        b.add({"kind": "key_down", "key": "w"}, _wasd(np.array([0.0, 0.0, -1.0])))
        b.add({"kind": "key_down", "key": "s"}, _wasd(np.array([0.0, 0.0, 1.0])))
        b.add({"kind": "key_down", "key": "a"}, _wasd(np.array([-1.0, 0.0, 0.0])))
        b.add({"kind": "key_down", "key": "d"}, _wasd(np.array([1.0, 0.0, 0.0])))

        def _mouse_look(event: InputEvent, ctx: BindingContext) -> Optional[ViewMutation]:
            if event.kind != "mouse_move":
                return None
            return ViewMutation(
                delta_yaw=-event.dx * b.look_sensitivity,
                delta_pitch=-event.dy * b.look_sensitivity,
            )

        b.add({"kind": "mouse_move"}, _mouse_look)

        def _scroll_zoom(event: InputEvent, ctx: BindingContext) -> Optional[ViewMutation]:
            if event.kind != "scroll":
                return None
            return ViewMutation(delta_scale=event.dy * b.scroll_zoom_factor)

        b.add({"kind": "scroll"}, _scroll_zoom)

        def _jump(event: InputEvent, ctx: BindingContext) -> Optional[ViewMutation]:
            if event.kind != "key_down" or event.key != "space":
                return None
            last = ctx.last_press_time.get("space", -1e9)
            if event.timestamp - last < b.double_tap_window:
                # Double-tap: toggle gravity mode.
                current = (ctx.current_view.gravity_mode
                           if ctx.current_view is not None else "world")
                new = "free" if current == "world" else "world"
                return ViewMutation(set_gravity_mode=new)
            return ViewMutation(delta_position=np.array([0.0, 1.0, 0.0]) * 4.0 * 0.016)

        b.add({"kind": "key_down", "key": "space"}, _jump)

        def _open_chat(event: InputEvent, ctx: BindingContext) -> Optional[ViewMutation]:
            if event.kind != "key_down" or event.key != "t":
                return None
            return ViewMutation(open_chat=True)

        b.add({"kind": "key_down", "key": "t"}, _open_chat)
        return b


def _matches(pattern: Dict[str, Any], event: InputEvent) -> bool:
    """A pattern matches an event when every present pattern field equals
    the event's value for that field. Absent fields wildcard."""
    for k, v in pattern.items():
        if getattr(event, k, None) != v:
            return False
    return True


# ---------------------------------------------------------------------------
# Mutation application — the bridge to View. Lives here (not engine/core)
# so the realtime renderer and headless tests share one implementation.
# ---------------------------------------------------------------------------


def apply_mutation(view: Any, mutation: ViewMutation) -> Any:
    """
    Apply a ViewMutation to a View, returning a new View. Used by the
    realtime renderer between frames and by headless test code.
    Pure: input view is unchanged.
    """
    from engine.node import View

    new_position = view.position.copy()
    new_orientation = view.orientation.copy()
    new_scale = view.scale
    new_gravity_mode = view.gravity_mode

    if mutation.delta_position is not None:
        # delta_position is in the viewer's local frame; transform to world.
        delta_world = view.orientation @ mutation.delta_position
        new_position = new_position + delta_world

    if mutation.delta_yaw != 0.0 or mutation.delta_pitch != 0.0 or mutation.delta_roll != 0.0:
        new_orientation = _apply_rotation(
            new_orientation,
            mutation.delta_yaw,
            mutation.delta_pitch,
            mutation.delta_roll,
            view.gravity_up if view.gravity_mode != "free" else None,
        )

    if mutation.delta_scale != 0.0:
        # log-additive: scale * exp(delta) keeps zoom multiplicative.
        new_scale = float(new_scale * np.exp(mutation.delta_scale))

    if mutation.set_gravity_mode is not None:
        new_gravity_mode = mutation.set_gravity_mode

    return View(
        position=new_position,
        orientation=new_orientation,
        scale=new_scale,
        width=view.width,
        height=view.height,
        fov_y_radians=view.fov_y_radians,
        gravity_mode=new_gravity_mode,
        gravity_up=view.gravity_up.copy(),
        time=view.time,
    )


def _apply_rotation(orientation: np.ndarray, yaw: float, pitch: float, roll: float,
                    gravity_up: Optional[np.ndarray]) -> np.ndarray:
    """Compose rotations onto orientation. In gravity modes, yaw is about
    the world's gravity_up; pitch is about the local right-axis; roll
    matches the local forward-axis. In free mode (gravity_up None), all
    three are about local axes so the viewer can rotate to any orientation
    on the sphere of orientations."""
    R = orientation.copy()
    # Local axes (columns): right=R[:,0], up=R[:,1], -forward=R[:,2].
    right = R[:, 0]
    forward = -R[:, 2]
    if yaw != 0.0:
        axis = gravity_up if gravity_up is not None else R[:, 1]
        R = _rot(axis, yaw) @ R
    if pitch != 0.0:
        R = _rot(right, pitch) @ R
    if roll != 0.0:
        R = _rot(forward, roll) @ R
    return R


def _rot(axis: np.ndarray, angle: float) -> np.ndarray:
    """Rodrigues rotation around axis."""
    axis = axis / (np.linalg.norm(axis) + 1e-12)
    K = np.array([[0, -axis[2], axis[1]],
                  [axis[2], 0, -axis[0]],
                  [-axis[1], axis[0], 0]])
    return np.eye(3) + np.sin(angle) * K + (1 - np.cos(angle)) * (K @ K)
