"""
Tooltip helper — SPEC-074 + SPEC-072 composition.

Small, focused widget-binding utility that surfaces a hover-name on
plain mouseover and extended help under Ctrl-hover. Lives in its own
module so any view / panel / node-type that renders Tk widgets can
attach a tooltip without pulling in the full ``gui_shell`` module.

Why a class (rather than a per-widget pair of bind calls). Three
reasons:

1. **Lifecycle ownership.** The Toplevel showing the tooltip is owned
   by the ``Tooltip`` instance; ``hide()`` is idempotent; teardown
   happens cleanly when the widget is destroyed.
2. **Ctrl-state composition.** SPEC-072 gates extended help on
   ``Ctrl`` being held. The ``Tooltip`` does NOT reimplement the
   ``Ctrl``-state machine — it consults a caller-supplied
   ``ctrl_held_getter`` callable (the shell's ``lambda: self.ctrl_held``).
   This keeps the gate logic single-sourced in ``gui_shell``.
3. **Headless-safe.** Constructing a ``Tooltip`` doesn't open any
   Toplevel; the widget is created on first ``show()``. Tests that
   want to assert "this widget has a tooltip registered with text X"
   can read ``tooltip.basic_text`` / ``tooltip.extended_text`` without
   touching Tk.

Usage from ``gui_shell``::

    from tools.workflow_gui.tooltip import Tooltip

    tip = Tooltip(
        widget=btn,
        basic_text="Archive",
        extended_text="Archive — Ctrl+click to fire; right-click for menu.",
        ctrl_held_getter=lambda: self.ctrl_held,
    )
    self._tooltips[widget_id] = tip   # keep alive for lookup + teardown

The ``Tooltip`` binds ``<Enter>`` and ``<Leave>`` on construction; if
``unbind()`` is called later, the bindings are removed and the
instance becomes inert. Re-binding the same widget twice (e.g. on a
sidebar rebuild) requires calling ``unbind()`` first or just letting
the prior instance get garbage-collected when the widget is destroyed
(Tk drops bindings when the widget goes).
"""

from __future__ import annotations

from typing import Any, Callable, Optional


class Tooltip:
    """Hover tooltip + Ctrl-hover extended help.

    Single instance per widget. Bind happens on construction; the
    instance is the source of truth for what text shows up under
    plain hover vs. Ctrl-hover.

    Attributes (read-only after construction):

    - ``widget`` — the Tk widget the tooltip is attached to.
    - ``basic_text`` — text shown on plain hover.
    - ``extended_text`` — text shown on Ctrl-hover; empty / ``None``
      ⇒ Ctrl-hover falls back to ``basic_text``.
    - ``ctrl_held_getter`` — callable returning the current Ctrl
      state (``True`` ⇒ Ctrl is held). SPEC-072 single-sources this
      in the shell.

    Mutable state:

    - ``_tip_window`` — the live Toplevel when a tooltip is visible;
      ``None`` when hidden. Tests can assert ``tip._tip_window is
      not None`` to confirm visibility without poking at Tk's
      window manager.
    """

    def __init__(
        self,
        widget: Any,
        basic_text: str,
        *,
        extended_text: str = "",
        ctrl_held_getter: Optional[Callable[[], bool]] = None,
        bg: str = "#15171c",
        fg: str = "#e8e8ec",
        font: tuple = ("Helvetica", 9),
        wraplength: int = 320,
        offset_x: int = 8,
        offset_y: int = 4,
    ) -> None:
        self.widget = widget
        self.basic_text = basic_text
        self.extended_text = extended_text or ""
        self.ctrl_held_getter = ctrl_held_getter
        self.bg = bg
        self.fg = fg
        self.font = font
        self.wraplength = wraplength
        self.offset_x = offset_x
        self.offset_y = offset_y
        self._tip_window: Any = None
        # Track bind ids so unbind() can remove exactly the handlers
        # we added rather than clobbering caller-installed ones.
        self._enter_bind_id: Optional[str] = None
        self._leave_bind_id: Optional[str] = None
        try:
            self._enter_bind_id = widget.bind("<Enter>", self._on_enter, add="+")
            self._leave_bind_id = widget.bind("<Leave>", self._on_leave, add="+")
        except Exception:
            # Widget might not be a real Tk widget (headless test
            # stubs); leave bindings empty and rely on direct
            # show()/hide() calls.
            pass

    # ----- public API -----

    def text_for_state(self, ctrl_held: Optional[bool] = None) -> str:
        """Return the text that *would* show given a Ctrl state.

        Public for tests + the text-API ``tooltip-for`` /
        ``extended-help-for`` verbs. Passing ``None`` consults the
        getter; passing an explicit bool overrides (useful for tests
        of both branches without a real keyboard event).
        """
        if ctrl_held is None:
            try:
                ctrl_held = bool(self.ctrl_held_getter()) if self.ctrl_held_getter else False
            except Exception:
                ctrl_held = False
        if ctrl_held and self.extended_text:
            return self.extended_text
        return self.basic_text

    def show(self, ctrl_held: Optional[bool] = None) -> Any:
        """Display the tooltip Toplevel anchored to the widget.

        Returns the Toplevel (or ``None`` when Tk isn't reachable).
        Idempotent: a second call hides the prior window first so
        the tooltip never doubles up.
        """
        self.hide()
        text = self.text_for_state(ctrl_held=ctrl_held)
        if not text:
            return None
        try:
            import tkinter as tk
        except Exception:
            return None
        try:
            x = self.widget.winfo_rootx() + self.widget.winfo_width() + self.offset_x
            y = self.widget.winfo_rooty() + self.offset_y
        except Exception:
            return None
        try:
            tip = tk.Toplevel(self.widget)
            tip.wm_overrideredirect(True)
            tip.wm_geometry(f"+{x}+{y}")
            label = tk.Label(
                tip,
                text=text,
                bg=self.bg,
                fg=self.fg,
                font=self.font,
                wraplength=self.wraplength,
                justify="left",
                padx=8,
                pady=4,
                borderwidth=1,
                relief="solid",
            )
            label.pack()
        except Exception:
            return None
        self._tip_window = tip
        return tip

    def hide(self) -> None:
        """Destroy the live tooltip Toplevel if one exists.

        Idempotent. Catches every Tk exception (the widget may
        already be destroyed by the time hide() is called from a
        deferred ``<Leave>``).
        """
        if self._tip_window is None:
            return
        try:
            self._tip_window.destroy()
        except Exception:
            pass
        self._tip_window = None

    def unbind(self) -> None:
        """Remove the ``<Enter>`` / ``<Leave>`` bindings + hide.

        Useful when re-binding a fresh ``Tooltip`` over the same
        widget (e.g. sidebar rebuild). After unbind() the instance
        is inert — ``show()`` still works but no hover event fires
        it.
        """
        self.hide()
        for seq, bid in (
            ("<Enter>", self._enter_bind_id),
            ("<Leave>", self._leave_bind_id),
        ):
            if bid is None:
                continue
            try:
                self.widget.unbind(seq, bid)
            except Exception:
                pass
        self._enter_bind_id = None
        self._leave_bind_id = None

    def update_text(
        self,
        basic_text: Optional[str] = None,
        extended_text: Optional[str] = None,
    ) -> None:
        """Replace the registered text without rebinding.

        Useful when the tooltip's text depends on state that
        changes (e.g. a Lock toggle's tooltip swaps "Lock" /
        "Unlock"). If a tooltip is currently visible, it stays
        visible with the new text on next hover; we deliberately
        don't repaint the live Toplevel to avoid a flicker.
        """
        if basic_text is not None:
            self.basic_text = basic_text
        if extended_text is not None:
            self.extended_text = extended_text

    # ----- event handlers -----

    def _on_enter(self, _event: Any) -> None:
        # Read Ctrl state lazily so the same Tooltip can swap branches
        # mid-hover if the maintainer presses Ctrl while hovering.
        self.show()

    def _on_leave(self, _event: Any) -> None:
        self.hide()


__all__ = ["Tooltip"]
