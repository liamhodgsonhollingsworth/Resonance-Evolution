"""
Tests for the Tooltip helper class (SPEC-074 + SPEC-072 composition).

Two coverage layers:

- **Headless** — text resolution, ``text_for_state`` branches, default
  fallbacks, ``update_text`` mutation, ``unbind`` idempotence. These
  tests use a stub widget so no Tk root is required.
- **Tk-dependent** — ``show()`` / ``hide()`` Toplevel lifecycle when a
  real Tk root is available. Skipped when ``tkinter.Tk()`` can't be
  constructed (CI / headless sandbox).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import pytest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.workflow_gui.tooltip import Tooltip


# ---------------------------------------------------------------------------
# Stubs.
# ---------------------------------------------------------------------------


class _StubWidget:
    """Minimal stub matching the slice of Tk widget API Tooltip touches."""

    def __init__(self) -> None:
        self.bindings: dict = {}

    def bind(self, sequence: str, callback: Any, add: str = "") -> str:
        bid = f"bind-{sequence}-{len(self.bindings)}"
        self.bindings[bid] = (sequence, callback)
        return bid

    def unbind(self, sequence: str, funcid: str = "") -> None:
        # Remove just the matching id (so tests can verify selective
        # teardown).
        if funcid and funcid in self.bindings:
            del self.bindings[funcid]


# ---------------------------------------------------------------------------
# Construction + text resolution
# ---------------------------------------------------------------------------


def test_basic_text_only_returns_basic_under_any_ctrl_state():
    tip = Tooltip(widget=_StubWidget(), basic_text="Archive")
    assert tip.text_for_state(False) == "Archive"
    assert tip.text_for_state(True) == "Archive"


def test_extended_text_used_under_ctrl_hover():
    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Archive",
        extended_text="Archive — Ctrl+click fires; right-click menu.",
    )
    assert tip.text_for_state(False) == "Archive"
    assert tip.text_for_state(True) == "Archive — Ctrl+click fires; right-click menu."


def test_extended_falls_back_to_basic_when_extended_is_empty():
    tip = Tooltip(widget=_StubWidget(), basic_text="Send", extended_text="")
    assert tip.text_for_state(True) == "Send"


def test_ctrl_held_getter_consulted_when_no_explicit_state():
    state = {"held": False}
    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Lock",
        extended_text="Lock — pin in place.",
        ctrl_held_getter=lambda: state["held"],
    )
    assert tip.text_for_state() == "Lock"
    state["held"] = True
    assert tip.text_for_state() == "Lock — pin in place."


def test_ctrl_held_getter_default_false_when_none_supplied():
    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Inbox",
        extended_text="Inbox — main inbox; Ctrl+click archives.",
    )
    # No getter → defaults to False → basic text under no-args call.
    assert tip.text_for_state() == "Inbox"


def test_ctrl_held_getter_exception_treated_as_false():
    """If the caller's getter throws (e.g. shell torn down), the
    tooltip must not propagate — it falls back to basic."""

    def _boom() -> bool:
        raise RuntimeError("shell torn down")

    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Tasks",
        extended_text="Tasks — extended help.",
        ctrl_held_getter=_boom,
    )
    assert tip.text_for_state() == "Tasks"


# ---------------------------------------------------------------------------
# Binding semantics
# ---------------------------------------------------------------------------


def test_construction_binds_enter_and_leave_on_widget():
    w = _StubWidget()
    Tooltip(widget=w, basic_text="X")
    sequences = {seq for (seq, _cb) in w.bindings.values()}
    assert sequences == {"<Enter>", "<Leave>"}


def test_unbind_removes_the_handlers_we_added():
    w = _StubWidget()
    tip = Tooltip(widget=w, basic_text="X")
    assert len(w.bindings) == 2
    tip.unbind()
    assert w.bindings == {}


def test_unbind_is_idempotent():
    w = _StubWidget()
    tip = Tooltip(widget=w, basic_text="X")
    tip.unbind()
    tip.unbind()  # Should not raise.


def test_unbind_clears_internal_bind_ids():
    """After unbind() the instance's stored bind ids should be None
    so a second unbind doesn't double-call the widget's unbind."""
    w = _StubWidget()
    tip = Tooltip(widget=w, basic_text="X")
    tip.unbind()
    assert tip._enter_bind_id is None
    assert tip._leave_bind_id is None


# ---------------------------------------------------------------------------
# update_text mutation
# ---------------------------------------------------------------------------


def test_update_text_replaces_basic_only():
    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Lock",
        extended_text="Lock — extended.",
    )
    tip.update_text(basic_text="Unlock")
    assert tip.basic_text == "Unlock"
    assert tip.extended_text == "Lock — extended."  # unchanged


def test_update_text_replaces_extended_only():
    tip = Tooltip(
        widget=_StubWidget(),
        basic_text="Lock",
        extended_text="Lock — extended.",
    )
    tip.update_text(extended_text="Lock — new extended help.")
    assert tip.basic_text == "Lock"
    assert tip.extended_text == "Lock — new extended help."


def test_update_text_handles_none_args_as_noop():
    tip = Tooltip(widget=_StubWidget(), basic_text="X", extended_text="Y")
    tip.update_text()  # Both None → no change.
    assert tip.basic_text == "X"
    assert tip.extended_text == "Y"


# ---------------------------------------------------------------------------
# hide() lifecycle (no Tk required for the no-window branch)
# ---------------------------------------------------------------------------


def test_hide_is_idempotent_when_no_window_is_open():
    tip = Tooltip(widget=_StubWidget(), basic_text="X")
    assert tip._tip_window is None
    tip.hide()  # Must not raise.
    tip.hide()
    assert tip._tip_window is None


def test_show_returns_none_when_widget_has_no_tk_root():
    """A pure stub widget can't provide ``winfo_rootx`` etc., so
    ``show()`` must gracefully no-op rather than raise."""
    tip = Tooltip(widget=_StubWidget(), basic_text="X")
    result = tip.show()
    assert result is None
    assert tip._tip_window is None


def test_show_returns_none_when_basic_text_is_empty_string():
    tip = Tooltip(widget=_StubWidget(), basic_text="")
    assert tip.show() is None


# ---------------------------------------------------------------------------
# Tk-dependent: live Toplevel lifecycle
# ---------------------------------------------------------------------------


def _make_tk_root():
    try:
        import tkinter as tk
    except Exception:  # pragma: no cover - no tkinter at all
        return None
    try:
        root = tk.Tk()
        root.withdraw()
        return root
    except Exception:  # pragma: no cover - no display
        return None


def test_show_creates_toplevel_when_tk_root_available():
    root = _make_tk_root()
    if root is None:
        pytest.skip("Tk root not available")
    try:
        import tkinter as tk
        btn = tk.Button(root, text="X")
        btn.pack()
        root.update_idletasks()
        tip = Tooltip(widget=btn, basic_text="Hover me")
        result = tip.show(ctrl_held=False)
        assert result is not None
        assert tip._tip_window is not None
        tip.hide()
        assert tip._tip_window is None
    finally:
        root.destroy()


def test_show_then_show_replaces_prior_window():
    root = _make_tk_root()
    if root is None:
        pytest.skip("Tk root not available")
    try:
        import tkinter as tk
        btn = tk.Button(root, text="X")
        btn.pack()
        root.update_idletasks()
        tip = Tooltip(widget=btn, basic_text="A", extended_text="B")
        first = tip.show(ctrl_held=False)
        assert first is not None
        second = tip.show(ctrl_held=True)
        assert second is not None
        # The two Toplevels are distinct objects; the second supersedes.
        assert first is not second
        # The stored _tip_window matches the second show.
        assert tip._tip_window is second
        tip.hide()
    finally:
        root.destroy()


def test_unbind_after_show_destroys_live_window():
    root = _make_tk_root()
    if root is None:
        pytest.skip("Tk root not available")
    try:
        import tkinter as tk
        btn = tk.Button(root, text="X")
        btn.pack()
        root.update_idletasks()
        tip = Tooltip(widget=btn, basic_text="Hover")
        tip.show(ctrl_held=False)
        assert tip._tip_window is not None
        tip.unbind()
        assert tip._tip_window is None
    finally:
        root.destroy()
