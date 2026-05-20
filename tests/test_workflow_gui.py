"""
Tests for the 2D Tk GUI workflow shell (SPEC-065).

Two layers of coverage:

- **Headless** — data providers, the tab catalog, tab-state-machine
  guards, the panel-id mapping. These tests run anywhere because they
  never construct a Tk window. They use stub objects in place of the
  engine / Inbox / SessionManager primitives.
- **Tk-dependent** — the embedded ``TkBackend`` lifecycle (open against
  a parent widget; close without destroying the parent), basic
  ``GuiShell.build_ui`` smoke that constructs and tears down the
  window without exercising the 3D loop. Skipped when tkinter isn't
  importable so CI / sandboxed environments don't fail spuriously.

The 3D embed integration is exercised through a stub backend so the
realtime driver loop doesn't depend on a real Tk display.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import pytest


# Ensure the Apeiron repo root is on sys.path so the tools.* / engine.*
# imports resolve when pytest runs from a subdir.
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.workflow_gui.gui_shell import (
    DEFAULT_TAB,
    GuiShell,
    TABS,
    items_from_engine_cache,
    items_from_inbox,
    items_from_sessions,
)


# ---------------------------------------------------------------------------
# Stubs.
# ---------------------------------------------------------------------------


class _StubEngine:
    def __init__(self, cache: Optional[Dict[str, Any]] = None) -> None:
        self.cache: Dict[str, Any] = dict(cache or {})
        self.errors: List[str] = []
        self.precompute_calls = 0

    def precompute(self) -> None:
        self.precompute_calls += 1


class _StubInbox:
    def __init__(self, messages: Optional[List[Any]] = None) -> None:
        self._messages = list(messages or [])

    def list_main(self, unread_only: bool = False) -> List[Any]:
        if unread_only:
            return [m for m in self._messages if not m.read]
        return list(self._messages)


class _StubSession:
    def __init__(
        self,
        sid: str,
        display_name: str,
        session_type: str = "workflow-management",
        status: str = "active",
    ) -> None:
        self.id = sid
        self.display_name = display_name
        self.session_type = session_type
        self.status = status


class _StubSessionManager:
    def __init__(
        self,
        records: Optional[List[_StubSession]] = None,
        state_dir: Optional[Path] = None,
    ) -> None:
        self._records = list(records or [])
        self.sent: List[Dict[str, str]] = []
        self.state_dir = state_dir or Path(".")
        self.shutdown_called = False

    def list(self) -> List[_StubSession]:
        return list(self._records)

    def send(self, sid: str, message: str) -> None:
        self.sent.append({"sid": sid, "message": message})

    def get(self, sid: str) -> Optional[_StubSession]:
        for r in self._records:
            if r.id == sid:
                return r
        return None

    def spawn(
        self,
        *,
        session_type: str,
        display_name: Optional[str] = None,
        cwd: Optional[Path] = None,
        seed_message: Optional[str] = None,
    ) -> _StubSession:
        rec = _StubSession(
            sid=f"stub-{len(self._records)+1}",
            display_name=display_name or "stub",
            session_type=session_type,
        )
        self._records.append(rec)
        return rec

    def shutdown(self) -> None:
        self.shutdown_called = True


def _make_shell(
    *,
    engine: Optional[_StubEngine] = None,
    inbox: Optional[_StubInbox] = None,
    sm: Optional[_StubSessionManager] = None,
    scene_path: Optional[Path] = None,
    scene_root_id: Optional[str] = None,
    current_user: Optional[str] = None,
) -> GuiShell:
    return GuiShell(
        engine=engine or _StubEngine(),
        session_manager=sm or _StubSessionManager(),
        inbox=inbox or _StubInbox(),
        root=Path("."),
        scene_path=scene_path,
        scene_root_id=scene_root_id,
        current_user=current_user,
    )


# ---------------------------------------------------------------------------
# Tab catalog invariants.
# ---------------------------------------------------------------------------


def test_default_tab_is_present_in_tabs():
    names = [t[0] for t in TABS]
    assert DEFAULT_TAB in names


def test_tabs_includes_all_required_surfaces():
    """SPEC-065 names Tasks, Ideas, Wishlist, Inbox, Chat, Quarantine,
    Trusted Senders, and a 3D tab. Every one must be in the catalog."""
    names = [t[0] for t in TABS]
    for required in (
        "Tasks",
        "Ideas",
        "Wishlist",
        "Inbox",
        "Chat",
        "Quarantine",
        "Trusted Senders",
        "3D",
    ):
        assert required in names, f"missing tab: {required}"


def test_panel_id_mapping_includes_existing_renderer_ids():
    """The renderer-backed tabs map to the panel node-ids that
    ``scenes/workflow_view.json`` already defines."""
    shell = _make_shell()
    assert shell.panel_id_for_tab("Tasks") == "task_panel"
    assert shell.panel_id_for_tab("Wishlist") == "wish_panel"
    assert shell.panel_id_for_tab("Quarantine") == "quarantine_panel"
    assert shell.panel_id_for_tab("Trusted Senders") == "trusted_senders_panel"


def test_panel_id_for_inbox_and_chat_and_3d_is_none():
    """The GUI-direct tabs and the 3D tab have no panel renderer."""
    shell = _make_shell()
    assert shell.panel_id_for_tab("Inbox") is None
    assert shell.panel_id_for_tab("Chat") is None
    assert shell.panel_id_for_tab("3D") is None


# ---------------------------------------------------------------------------
# Data providers — engine cache.
# ---------------------------------------------------------------------------


def test_items_from_engine_cache_returns_empty_for_unknown_source():
    engine = _StubEngine(cache={})
    assert items_from_engine_cache(engine, "missing") == []


def test_items_from_engine_cache_returns_items_for_known_source():
    items = [
        {"id": "1", "title": "task one", "status": "pending"},
        {"id": "2", "title": "task two", "status": "done"},
    ]
    engine = _StubEngine(cache={"tasks_source": {"items": items}})
    assert items_from_engine_cache(engine, "tasks_source") == items


def test_items_from_engine_cache_handles_non_dict_cache_entry():
    engine = _StubEngine(cache={"bad": "not a dict"})  # type: ignore[arg-type]
    assert items_from_engine_cache(engine, "bad") == []


def test_items_from_engine_cache_handles_non_list_items():
    engine = _StubEngine(cache={"bad": {"items": "string not list"}})
    assert items_from_engine_cache(engine, "bad") == []


def test_items_from_engine_cache_empty_source_id():
    engine = _StubEngine()
    assert items_from_engine_cache(engine, "") == []


# ---------------------------------------------------------------------------
# Data providers — inbox.
# ---------------------------------------------------------------------------


def test_items_from_inbox_renders_each_message_as_item():
    msg_a = SimpleNamespace(
        path=Path("inbox_001.md"),
        sender="apeiron",
        to="LHH",
        kind="note",
        summary="hello",
        ts=time.time(),
        body="hello body",
        read=False,
    )
    msg_b = SimpleNamespace(
        path=Path("inbox_002.md"),
        sender="claude",
        to="LHH",
        kind="response",
        summary="ack",
        ts=time.time(),
        body="ack body",
        read=True,
    )
    inbox = _StubInbox(messages=[msg_a, msg_b])
    items = items_from_inbox(inbox)  # type: ignore[arg-type]
    assert len(items) == 2
    assert items[0]["id"] == "inbox_001.md"
    assert items[0]["status"] == "pending"  # unread → pending
    assert items[1]["status"] == "ok"  # read → ok
    assert "hello" in items[0]["title"]


def test_items_from_inbox_empty():
    items = items_from_inbox(_StubInbox(messages=[]))  # type: ignore[arg-type]
    assert items == []


# ---------------------------------------------------------------------------
# Data providers — sessions.
# ---------------------------------------------------------------------------


def test_items_from_sessions_marks_active_session():
    a = _StubSession(sid="aaa", display_name="alpha")
    b = _StubSession(sid="bbb", display_name="beta")
    sm = _StubSessionManager(records=[a, b])
    items = items_from_sessions(sm, active_id="aaa")  # type: ignore[arg-type]
    assert items[0]["title"].startswith("alpha")
    assert "(active)" in items[0]["title"]
    assert "(active)" not in items[1]["title"]


def test_items_from_sessions_includes_target_action():
    a = _StubSession(sid="aaa", display_name="alpha")
    sm = _StubSessionManager(records=[a])
    items = items_from_sessions(sm, active_id=None)  # type: ignore[arg-type]
    assert "target" in items[0]["actions"]
    assert "expand" in items[0]["actions"]


def test_items_from_sessions_status_mapping():
    cases = [
        ("active", "in_progress"),
        ("idle", "ok"),
        ("archived", "cancelled"),
        ("error", "alert"),
        ("unknown_state", "pending"),
    ]
    for raw, expected in cases:
        rec = _StubSession(sid="x", display_name="x", status=raw)
        sm = _StubSessionManager(records=[rec])
        items = items_from_sessions(sm, active_id=None)  # type: ignore[arg-type]
        assert items[0]["status"] == expected, f"{raw} -> {items[0]['status']} (expected {expected})"


# ---------------------------------------------------------------------------
# Tab state machine.
# ---------------------------------------------------------------------------


def test_can_switch_to_known_tab_returns_true():
    shell = _make_shell()
    assert shell.can_switch_to("Tasks") is True
    assert shell.can_switch_to("3D") is True


def test_can_switch_to_unknown_tab_returns_false():
    shell = _make_shell()
    assert shell.can_switch_to("DoesNotExist") is False


def test_select_tab_records_active_tab_without_ui():
    shell = _make_shell()
    assert shell.select_tab("Tasks") is True
    assert shell.active_tab == "Tasks"


def test_select_tab_returns_false_for_unknown_tab():
    shell = _make_shell()
    assert shell.select_tab("DoesNotExist") is False
    assert shell.active_tab is None


def test_select_tab_clears_expanded_item_id():
    shell = _make_shell()
    shell.select_tab("Tasks")
    shell._expanded_item_id = "some-id"
    shell.select_tab("Wishlist")
    assert shell._expanded_item_id is None


def test_select_tab_to_3d_does_not_teardown_when_already_3d():
    """Switching from 3D to 3D leaves the driver alone — teardown only
    happens when switching AWAY from 3D."""
    shell = _make_shell()
    fake_driver = SimpleNamespace(request_quit=lambda: None)
    shell._driver = fake_driver  # type: ignore[assignment]
    shell.active_tab = "3D"
    # Selecting 3D again should not zero the driver out.
    shell.select_tab("3D")
    assert shell._driver is fake_driver


def test_select_tab_to_2d_tears_down_3d_driver():
    """Switching to any 2D tab while the 3D driver is active triggers
    the teardown branch (driver + backend cleared)."""
    shell = _make_shell()
    closed = {"backend": False}

    class _FakeBackend:
        def close(self):
            closed["backend"] = True

    shell._driver = SimpleNamespace(request_quit=lambda: None)  # type: ignore[assignment]
    shell._backend = _FakeBackend()  # type: ignore[assignment]
    shell._frame_pump_active = True
    shell.active_tab = "3D"
    shell.select_tab("Tasks")
    assert shell._driver is None
    assert shell._backend is None
    assert closed["backend"] is True
    assert shell._frame_pump_active is False


# ---------------------------------------------------------------------------
# items_for_tab routing.
# ---------------------------------------------------------------------------


def test_items_for_tab_routes_inbox_to_inbox_provider():
    msg = SimpleNamespace(
        path=Path("inbox_001.md"),
        sender="x",
        to="y",
        kind="k",
        summary="s",
        ts=time.time(),
        body="b",
        read=False,
    )
    shell = _make_shell(inbox=_StubInbox(messages=[msg]))
    items = shell.items_for_tab("Inbox")
    assert len(items) == 1
    assert items[0]["id"] == "inbox_001.md"


def test_items_for_tab_routes_chat_to_session_provider():
    rec = _StubSession(sid="abc", display_name="alpha")
    shell = _make_shell(sm=_StubSessionManager(records=[rec]))
    items = shell.items_for_tab("Chat")
    assert len(items) == 1
    assert items[0]["id"] == "abc"


def test_items_for_tab_routes_source_to_engine_cache():
    cache = {"tasks_source": {"items": [{"id": "t1", "title": "one"}]}}
    shell = _make_shell(engine=_StubEngine(cache=cache))
    items = shell.items_for_tab("Tasks")
    assert items == [{"id": "t1", "title": "one"}]


def test_items_for_tab_3d_returns_empty():
    shell = _make_shell()
    assert shell.items_for_tab("3D") == []


def test_items_for_tab_unknown_returns_empty():
    shell = _make_shell()
    assert shell.items_for_tab("Nope") == []


# ---------------------------------------------------------------------------
# Chat submit routing.
# ---------------------------------------------------------------------------


def test_chat_submit_sends_to_active_session():
    sm = _StubSessionManager(records=[_StubSession(sid="aaa", display_name="alpha")])
    shell = _make_shell(sm=sm)
    shell.active_session_id = "aaa"

    class _FakeEntry:
        def __init__(self, text):
            self._text = text
            self._inserted = []

        def get(self):
            return self._text

        def delete(self, start, end):
            self._text = ""

        def insert(self, idx, text):
            self._inserted.append(text)

    shell._chat_entry = _FakeEntry("hello world")
    shell._on_chat_submit()
    assert sm.sent == [{"sid": "aaa", "message": "hello world"}]


def test_chat_submit_with_no_active_session_writes_hint():
    sm = _StubSessionManager(records=[])
    shell = _make_shell(sm=sm)
    shell.active_session_id = None

    class _FakeEntry:
        def __init__(self, text):
            self._text = text
            self._inserted: List[str] = []

        def get(self):
            return self._text

        def delete(self, start, end):
            self._text = ""

        def insert(self, idx, text):
            self._inserted.append(text)
            self._text = text

    shell._chat_entry = _FakeEntry("hello")
    shell._on_chat_submit()
    assert sm.sent == []
    assert shell._chat_entry._inserted, "hint should be written into the chat entry"
    assert "no active session" in shell._chat_entry._inserted[0]


def test_chat_submit_empty_text_is_no_op():
    sm = _StubSessionManager()
    shell = _make_shell(sm=sm)
    shell.active_session_id = "any"

    class _FakeEntry:
        def get(self):
            return "   "

        def delete(self, start, end):
            pass

        def insert(self, idx, text):
            pass

    shell._chat_entry = _FakeEntry()
    shell._on_chat_submit()
    assert sm.sent == []


# ---------------------------------------------------------------------------
# Tk-dependent tests.
# ---------------------------------------------------------------------------


def _require_tk():
    try:
        import tkinter  # noqa: F401
    except Exception:
        pytest.skip("tkinter not available")
    # On Windows + headless CI we may have tkinter but no display.
    try:
        import tkinter as tk

        root = tk.Tk()
        root.withdraw()
        root.destroy()
    except Exception:
        pytest.skip("no display available for Tk root")


def test_tk_backend_embedded_mode_does_not_destroy_parent_on_close():
    """Calling ``close`` on an embedded TkBackend leaves the parent
    toplevel intact — only the embedded canvas goes away."""
    _require_tk()
    import tkinter as tk

    from engine.realtime_tk import TkBackend

    parent_root = tk.Tk()
    parent_root.withdraw()
    parent_frame = tk.Frame(parent_root, width=320, height=240)
    parent_frame.pack()
    backend = TkBackend()
    backend.open(width=320, height=240, parent=parent_frame)
    assert backend._owns_root is False
    backend.close()
    # Parent toplevel is still alive and operable.
    assert parent_root.winfo_exists() == 1
    parent_root.destroy()


def test_tk_backend_standalone_mode_still_works():
    """Backwards compatibility: ``open()`` without ``parent`` opens a
    dedicated window and closes it on ``close``."""
    _require_tk()
    from engine.realtime_tk import TkBackend

    backend = TkBackend()
    backend.open(width=320, height=240)
    assert backend._owns_root is True
    backend.close()
    assert backend.root is None


def test_tk_backend_poll_events_in_embedded_mode_does_not_call_update():
    """In embedded mode, the backend's poll_events must not call
    ``root.update()`` — the parent's mainloop owns event pumping.

    Verifying the property indirectly: after open(parent=...), the
    backend's ``_owns_root`` flag is False, so the update branch is
    skipped. A real poll then returns whatever's in the deque without
    touching Tk's loop.
    """
    _require_tk()
    import tkinter as tk

    from engine.realtime_tk import TkBackend

    parent_root = tk.Tk()
    parent_root.withdraw()
    parent_frame = tk.Frame(parent_root)
    parent_frame.pack()
    backend = TkBackend()
    backend.open(width=200, height=200, parent=parent_frame)
    # The deque is empty; poll should return [] without raising.
    events = backend.poll_events()
    assert events == []
    backend.close()
    parent_root.destroy()


def test_gui_shell_build_ui_smoke():
    """The shell's build_ui constructs a window with a sidebar +
    central pane + chat input, then closes cleanly."""
    _require_tk()
    shell = _make_shell(engine=_StubEngine(cache={"tasks_source": {"items": []}}))
    shell.build_ui()
    # Default tab should be selected.
    assert shell.active_tab == DEFAULT_TAB
    # All sidebar buttons should be present.
    for name, _, _ in TABS:
        assert name in shell._sidebar_buttons
    # Chat entry should exist.
    assert shell._chat_entry is not None
    # Clean shutdown.
    shell._on_close()
    assert shell.tk_root is None


def test_gui_shell_select_tab_with_ui_renders_panel():
    """After build_ui, select_tab triggers a re-render of the central
    pane (the central frame's children change)."""
    _require_tk()
    items = [{"id": "t1", "title": "task one", "status": "pending"}]
    shell = _make_shell(engine=_StubEngine(cache={"tasks_source": {"items": items}}))
    shell.build_ui()
    # Switching to Wishlist swaps the central children.
    shell.select_tab("Wishlist")
    assert shell.active_tab == "Wishlist"
    assert shell._central_frame.winfo_children(), "central frame should have content"
    shell._on_close()


def test_gui_shell_precompute_called_on_tab_switch():
    """Switching to a 2D tab triggers engine.precompute so the source
    caches reflect external edits."""
    _require_tk()
    engine = _StubEngine(cache={"tasks_source": {"items": []}})
    shell = _make_shell(engine=engine)
    shell.build_ui()
    initial_calls = engine.precompute_calls
    shell.select_tab("Wishlist")
    assert engine.precompute_calls > initial_calls
    shell._on_close()


# ---------------------------------------------------------------------------
# Hold-Ctrl edit mode (SPEC-072) + hover-help (SPEC-074).
# ---------------------------------------------------------------------------


def test_ctrl_held_flag_starts_false():
    shell = _make_shell()
    assert shell.ctrl_held is False


def test_set_ctrl_flips_flag():
    shell = _make_shell()
    shell._set_ctrl(True)
    assert shell.ctrl_held is True
    shell._set_ctrl(False)
    assert shell.ctrl_held is False


def test_tab_help_has_entry_for_every_tab():
    """SPEC-074 requires hover-help for every visible icon/tab. The
    catalog must cover every entry in TABS."""
    shell = _make_shell()
    for name, _, _ in TABS:
        assert name in shell._tab_help, f"missing help for tab: {name}"


def test_tab_order_initialized_from_tabs():
    """The reorderable tab order starts as a flat copy of TABS' names."""
    shell = _make_shell()
    assert shell._tab_order == [name for name, _, _ in TABS]


def test_sidebar_scale_default_is_one():
    """SPEC-072 baseline: toolbar is at 1.0x scale before any Ctrl-drag."""
    shell = _make_shell()
    assert shell._sidebar_scale == 1.0


def test_set_sidebar_scale_changes_state():
    shell = _make_shell()
    result = shell.set_sidebar_scale(1.5)
    assert result == 1.5
    assert shell._sidebar_scale == 1.5


def test_set_sidebar_scale_clamps_to_max():
    """SPEC-072 acceptance: scale cannot exceed 2.5 (toolbar can't eat
    central pane)."""
    shell = _make_shell()
    result = shell.set_sidebar_scale(10.0)
    assert result == 2.5
    assert shell._sidebar_scale == 2.5


def test_set_sidebar_scale_clamps_to_min():
    """SPEC-072 acceptance: scale cannot fall below 0.6 (toolbar can't
    vanish)."""
    shell = _make_shell()
    result = shell.set_sidebar_scale(0.1)
    assert result == 0.6
    assert shell._sidebar_scale == 0.6


def test_set_sidebar_scale_idempotent_no_op():
    """Setting the same scale twice does not re-render — callers can
    use the return value to detect whether the call actually changed
    state."""
    shell = _make_shell()
    shell.set_sidebar_scale(1.5)
    # Re-set to the same value; should still return the same value.
    result = shell.set_sidebar_scale(1.5)
    assert result == 1.5


def test_archive_tab_removes_from_tab_order():
    shell = _make_shell()
    shell._tab_order = ["Tasks", "Ideas", "Wishlist"]
    shell.active_tab = "Tasks"
    # _archive_tab tries to pack_forget the button; since UI isn't built,
    # the missing button is OK — the order-list mutation must still happen.
    result = shell._archive_tab("Ideas")
    assert result == "Ideas"
    assert "Ideas" not in shell._tab_order
    assert shell._tab_order == ["Tasks", "Wishlist"]


def test_archive_tab_falls_back_to_other_tab_when_archiving_active():
    """SPEC-072: archiving the active tab must select a fallback so the
    central pane doesn't display a now-archived surface."""
    shell = _make_shell()
    shell._tab_order = ["Tasks", "Ideas", "Wishlist"]
    shell.active_tab = "Tasks"
    shell._archive_tab("Tasks")
    assert shell.active_tab in shell._tab_order
    assert shell.active_tab != "Tasks"


def test_set_ctrl_false_hides_tooltip():
    """Releasing Ctrl after being held drops any extended tooltip
    currently shown — without this, an extended (Ctrl-hover) tooltip
    can persist into normal-mode after the modifier is released."""
    shell = _make_shell()
    # Establish ctrl-held state first (mimicking a real Ctrl-press).
    shell._set_ctrl(True)
    assert shell.ctrl_held is True

    class _Stub:
        def destroy(self):
            pass

    shell._tooltip_window = _Stub()  # type: ignore[assignment]
    shell._set_ctrl(False)  # release; should hide tooltip
    assert shell._tooltip_window is None
    assert shell.ctrl_held is False


def test_hold_ctrl_does_not_flip_when_already_held():
    """Idempotent: setting True when already True is a no-op (no double
    state changes, no duplicate tooltip lifecycle)."""
    shell = _make_shell()
    shell._set_ctrl(True)
    assert shell.ctrl_held is True
    shell._set_ctrl(True)
    assert shell.ctrl_held is True


def test_gui_shell_build_ui_registers_ctrl_bindings():
    """SPEC-072 acceptance: Ctrl-key bindings exist on the root window
    after build_ui."""
    _require_tk()
    shell = _make_shell()
    shell.build_ui()
    # bind_all returns a string of registered bindings; non-empty means
    # something is registered for that sequence.
    pressed = shell.tk_root.bind_all("<Control-KeyPress>")
    released_l = shell.tk_root.bind_all("<KeyRelease-Control_L>")
    assert pressed, "Control-KeyPress binding missing"
    assert released_l, "KeyRelease-Control_L binding missing"
    shell._on_close()
