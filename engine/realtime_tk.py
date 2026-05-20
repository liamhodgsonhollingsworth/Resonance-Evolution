"""
Tkinter backend for the realtime renderer.

Uses Python's built-in ``tkinter`` + Pillow's ``ImageTk`` to display the
engine's ``color`` channel as a live-updating image. No external
dependencies — Pillow is already required and tkinter ships with CPython.

The Tk event model is callback-driven, so this backend buffers events into
a deque that the driver drains each frame via ``poll_events()``. The
driver owns the loop; this backend never calls ``mainloop`` — it pumps Tk
manually via ``update()`` each poll.

The backend has two modes:

- **Standalone** (default, ``open(parent=None)``): the backend creates its
  own ``Tk`` root window. Used by ``tools.realtime`` for the dedicated 3D
  window and by the workflow shell's ``/realtime`` command.
- **Embedded** (``open(parent=<frame>)``): the backend attaches its
  Canvas to a parent widget supplied by the caller. The parent owns the
  mainloop; the backend skips its own ``update()`` calls and relies on
  the parent's loop to pump Tk events. Used by ``tools.workflow_gui`` to
  paint the 3D scene into the central pane of the 2D GUI shell
  (SPEC-065).

For dream-mode first-person mouse-look with pointer-lock, a future pygame
backend will be more appropriate. tkinter is sufficient for the workflow
surface (panels + clicks + chat) which is the immediate need.
"""

from __future__ import annotations

from collections import deque
import time
from typing import Any, Deque, List, Optional, Tuple

import numpy as np

from engine.input import InputEvent


# Tk → InputEvent key-name normalization. Keys not present here pass
# through lowercased so single-letter keys like "w"/"a"/"s"/"d" match the
# default Bindings entries directly.
_TK_KEY_NAME_MAP = {
    "Escape": "escape",
    "Return": "enter",
    "Tab": "tab",
    "BackSpace": "backspace",
    "Delete": "delete",
    "Up": "up",
    "Down": "down",
    "Left": "left",
    "Right": "right",
    "Shift_L": "shift",
    "Shift_R": "shift",
    "Control_L": "control",
    "Control_R": "control",
    "Alt_L": "alt",
    "Alt_R": "alt",
    "space": "space",
    "F1": "f1",
    "F2": "f2",
    "F3": "f3",
    "F4": "f4",
    "F5": "f5",
    "F11": "f11",
    "F12": "f12",
}


def normalize_tk_key(keysym: str) -> str:
    """Map a Tk ``keysym`` to the canonical key name the Bindings table
    expects. Lowercased single letters, named for specials.
    """
    if keysym in _TK_KEY_NAME_MAP:
        return _TK_KEY_NAME_MAP[keysym]
    return keysym.lower()


class TkBackend:
    """A :class:`engine.realtime.WindowBackend` driven by ``tkinter``."""

    def __init__(self) -> None:
        self.root = None  # type: ignore[assignment]
        self.canvas = None  # type: ignore[assignment]
        self._tk_image = None  # PhotoImage; keeps a ref so Tk doesn't gc it.
        self._events: Deque[InputEvent] = deque()
        self._should_close = False
        self._last_mouse_pos: Optional[Tuple[int, int]] = None
        self._width = 0
        self._height = 0
        self._t0 = time.perf_counter()
        self._fullscreen = False
        # Embedded mode: when True the backend's Canvas lives inside a
        # caller-supplied parent widget; the caller's mainloop pumps Tk.
        self._owns_root = True

    # --- backend protocol ---

    def open(
        self,
        width: int,
        height: int,
        title: str = "Apeiron",
        parent: Any = None,
    ) -> None:
        """Open the window.

        ``parent`` is optional. When ``None`` (default), the backend
        creates its own ``Tk`` root and runs as a dedicated window.
        When a Tk widget is supplied, the backend attaches its Canvas
        to that parent and treats the parent's toplevel as the root —
        ``poll_events`` skips the standalone ``update()`` calls and the
        parent's mainloop is expected to pump events. Used by the 2D
        GUI shell to embed the 3D renderer in the central pane
        (SPEC-065).
        """
        import tkinter as tk

        self._width = int(width)
        self._height = int(height)
        if parent is None:
            self.root = tk.Tk()
            self.root.title(title)
            self.root.geometry(f"{self._width}x{self._height}")
            canvas_parent = self.root
            self._owns_root = True
        else:
            # In embedded mode we keep a reference to the toplevel for
            # binding utilities (focus, attributes) but never destroy it
            # at close — that belongs to the parent's lifecycle.
            self.root = parent.winfo_toplevel()
            canvas_parent = parent
            self._owns_root = False
        # Don't let Tk swallow Escape — handle it via the regular keymap.
        # In embedded mode we still bind globally so the 3D tab's key events
        # are visible whenever the GUI window has focus; the GUI shell
        # tears the backend down before activating a 2D tab so global
        # keys cannot leak between tabs.
        self.root.bind_all("<KeyPress>", self._on_key_down)
        self.root.bind_all("<KeyRelease>", self._on_key_up)
        self.canvas = tk.Canvas(
            canvas_parent,
            width=self._width,
            height=self._height,
            bg="black",
            highlightthickness=0,
        )
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Motion>", self._on_motion)
        self.canvas.bind("<Button-1>", lambda e: self._on_button(e, "left", True))
        self.canvas.bind("<ButtonRelease-1>", lambda e: self._on_button(e, "left", False))
        self.canvas.bind("<Button-3>", lambda e: self._on_button(e, "right", True))
        self.canvas.bind("<ButtonRelease-3>", lambda e: self._on_button(e, "right", False))
        # MouseWheel on Windows; Linux uses Button-4/5; Mac varies.
        self.canvas.bind("<MouseWheel>", self._on_wheel)
        self.canvas.bind("<Button-4>", lambda e: self._on_wheel_unix(e, +1))
        self.canvas.bind("<Button-5>", lambda e: self._on_wheel_unix(e, -1))
        # In standalone mode, hook the window-close protocol so the user
        # closing the window signals the driver to quit. Embedded mode
        # leaves the parent's WM_DELETE_WINDOW handler alone.
        if self._owns_root:
            self.root.protocol("WM_DELETE_WINDOW", self._on_close_protocol)
            self.root.focus_set()
        else:
            # Give the embedded canvas keyboard focus when the pointer
            # enters it so WASD / Esc go to the 3D scene rather than the
            # 2D shell's chat input.
            self.canvas.bind("<Enter>", lambda _e: self.canvas.focus_set())
            self.canvas.focus_set()

    def poll_events(self) -> List[InputEvent]:
        if self.root is None:
            return []
        # Embedded mode delegates the Tk pump to the parent's mainloop;
        # calling update() ourselves from inside a parent's after()
        # callback can re-enter the event loop and crash. Standalone
        # mode owns the loop and must pump every poll.
        if self._owns_root:
            try:
                self.root.update_idletasks()
                self.root.update()
            except Exception:
                # Window was destroyed mid-update; treat as quit signal.
                self._should_close = True
                return []
        out = list(self._events)
        self._events.clear()
        return out

    def blit_color(self, color_array: np.ndarray) -> None:
        from PIL import Image, ImageTk

        if self.root is None or self.canvas is None:
            return
        try:
            img = Image.fromarray(color_array, mode="RGB")
            # Resize to current canvas dims so the user can stretch the
            # window without breaking the blit.
            cur_w = max(1, self.canvas.winfo_width())
            cur_h = max(1, self.canvas.winfo_height())
            if (img.size[0], img.size[1]) != (cur_w, cur_h):
                img = img.resize((cur_w, cur_h), Image.NEAREST)
            self._tk_image = ImageTk.PhotoImage(img)
            self.canvas.delete("all")
            self.canvas.create_image(0, 0, anchor="nw", image=self._tk_image)
        except Exception:
            # Best-effort: a single bad frame must not crash the loop.
            pass

    def should_close(self) -> bool:
        return self._should_close

    def close(self) -> None:
        # Embedded mode: tear down the canvas + per-canvas bindings but
        # leave the parent toplevel alone — destroying it would kill the
        # GUI shell hosting us.
        if self.canvas is not None and not self._owns_root:
            try:
                self.canvas.destroy()
            except Exception:
                pass
        if self.root is not None and self._owns_root:
            try:
                self.root.destroy()
            except Exception:
                pass
        # Drop bind_all callbacks the embedded backend installed on the
        # parent's root so a re-activated tab doesn't double-fire them.
        if not self._owns_root and self.root is not None:
            try:
                self.root.unbind_all("<KeyPress>")
                self.root.unbind_all("<KeyRelease>")
            except Exception:
                pass
        self.root = None
        self.canvas = None
        self._tk_image = None
        self._owns_root = True

    def set_title(self, title: str) -> None:
        if self.root is not None:
            try:
                self.root.title(title)
            except Exception:
                pass

    def set_fullscreen(self, fullscreen: bool) -> None:
        """Toggle Tk's ``-fullscreen`` attribute. No-op if root missing."""
        if self.root is None:
            return
        try:
            self.root.attributes("-fullscreen", bool(fullscreen))
            self._fullscreen = bool(fullscreen)
        except Exception:
            # Some Tk builds (or remote-display setups) reject the attribute;
            # remain in normal mode silently.
            pass

    def is_fullscreen(self) -> bool:
        return self._fullscreen

    # --- internal event translators ---

    def _now(self) -> float:
        return time.perf_counter() - self._t0

    def _on_key_down(self, event) -> None:
        key = normalize_tk_key(event.keysym)
        self._events.append(InputEvent(kind="key_down", key=key, timestamp=self._now()))

    def _on_key_up(self, event) -> None:
        key = normalize_tk_key(event.keysym)
        self._events.append(InputEvent(kind="key_up", key=key, timestamp=self._now()))

    def _on_motion(self, event) -> None:
        if self._last_mouse_pos is None:
            self._last_mouse_pos = (event.x, event.y)
            return
        dx = float(event.x - self._last_mouse_pos[0])
        dy = float(event.y - self._last_mouse_pos[1])
        self._last_mouse_pos = (event.x, event.y)
        if dx == 0.0 and dy == 0.0:
            return
        self._events.append(
            InputEvent(
                kind="mouse_move",
                dx=dx,
                dy=dy,
                x=int(event.x),
                y=int(event.y),
                timestamp=self._now(),
            )
        )

    def _on_button(self, event, button: str, pressed: bool) -> None:
        self._events.append(
            InputEvent(
                kind="mouse_button",
                button=button,
                pressed=pressed,
                x=int(event.x),
                y=int(event.y),
                timestamp=self._now(),
            )
        )

    def _on_wheel(self, event) -> None:
        # Windows: event.delta in multiples of 120. Positive = up/away.
        dy = float(event.delta) / 120.0
        self._events.append(InputEvent(kind="scroll", dy=dy, timestamp=self._now()))

    def _on_wheel_unix(self, event, direction: int) -> None:
        # X11 / Linux: Button-4 = scroll up, Button-5 = scroll down.
        self._events.append(
            InputEvent(kind="scroll", dy=float(direction), timestamp=self._now())
        )

    def _on_close_protocol(self) -> None:
        self._should_close = True
