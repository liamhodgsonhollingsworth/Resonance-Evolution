"""
Integration tests for SPEC-067 view-as-menu across the gui_shell,
gui_test_driver, and the text-API ``set-view`` command.

The unit tests for ``ViewRegistry`` itself live at
``tests/test_view_registry.py``; this file pins the wiring between the
registry and its three consumers.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.gui_test_driver import GuiDriver
from tools.workflow_gui.gui_shell import GuiShell, items_from_text_view
from tools.workflow_gui.view_registry import (
    ViewRegistry,
    ViewSpec,
    default_view_registry,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_driver() -> GuiDriver:
    drv = GuiDriver()
    drv.build()
    return drv


# ---------------------------------------------------------------------------
# Shell <-> registry wiring.
# ---------------------------------------------------------------------------


def test_shell_attaches_registry_to_engine():
    """The shell must publish its registry on the engine so the
    text-API ``set-view`` command can find it without importing
    GUI modules."""
    drv = _make_driver()
    assert getattr(drv.shell.engine, "view_registry", None) is drv.shell.view_registry


def test_shell_attaches_gui_shell_to_engine():
    drv = _make_driver()
    assert getattr(drv.shell.engine, "gui_shell", None) is drv.shell


def test_shell_uses_custom_registry_when_supplied():
    """Constructing a GuiShell with an explicit registry uses it
    instead of the default."""
    from tools.gui_test_driver import _StubEngine, _StubInbox, _StubSessionManager

    custom = ViewRegistry()
    custom.register(ViewSpec(name="OnlyOne", kind="gui_inbox"))
    shell = GuiShell(
        engine=_StubEngine(),
        session_manager=_StubSessionManager(),
        inbox=_StubInbox(),
        root=Path("."),
        scene_path=None,
        scene_root_id=None,
        view_registry=custom,
    )
    assert shell.view_registry is custom
    assert shell.list_views() == ["OnlyOne"]


# ---------------------------------------------------------------------------
# set_view + current_view + list_views.
# ---------------------------------------------------------------------------


def test_set_view_activates_named_view():
    drv = _make_driver()
    assert drv.set_view("Ideas") is True
    assert drv.current_view() == "Ideas"


def test_set_view_unknown_returns_false():
    drv = _make_driver()
    assert drv.set_view("Nonexistent") is False


def test_set_view_restores_archived():
    """SPEC-067 acceptance: every view is reachable from every other
    view. An archived view must still be activatable; set_view restores
    it if needed."""
    drv = _make_driver()
    drv.hold_ctrl()
    drv.ctrl_click("Wishlist")  # archive Wishlist
    assert "Wishlist" not in drv.list_views()
    # set_view should restore + activate.
    assert drv.set_view("Wishlist") is True
    assert drv.current_view() == "Wishlist"
    assert "Wishlist" in drv.list_views()


def test_current_view_starts_none_in_headless():
    """In headless mode the shell's ``build_ui`` is skipped so no tab
    is auto-selected. Real Tk-launched shells call ``select_tab(DEFAULT_TAB)``
    from inside ``build_ui``."""
    drv = _make_driver()
    assert drv.current_view() is None


def test_current_view_set_via_set_view():
    drv = _make_driver()
    drv.set_view("Ideas")
    assert drv.current_view() == "Ideas"


def test_list_views_returns_default_set():
    drv = _make_driver()
    views = drv.list_views()
    for name in ("Tasks", "Ideas", "Wishlist", "Inbox", "Chat",
                 "Quarantine", "Trusted Senders", "3D", "Logs"):
        assert name in views


def test_register_view_at_runtime():
    drv = _make_driver()
    initial_count = len(drv.list_views())
    spec = ViewSpec(
        name="Custom",
        kind="text",
        description="Runtime-added view",
        text_body="Hello from runtime.",
    )
    drv.register_view(spec)
    assert len(drv.list_views()) == initial_count + 1
    assert "Custom" in drv.list_views()
    # And it must be reachable via set_view.
    assert drv.set_view("Custom") is True
    assert drv.current_view() == "Custom"


def test_register_view_replaces_existing():
    drv = _make_driver()
    initial_count = len(drv.list_views())
    drv.register_view(
        ViewSpec(name="Tasks", kind="text", description="overridden", text_body="new")
    )
    # Count unchanged; spec replaced.
    assert len(drv.list_views()) == initial_count
    spec = drv.shell.view_registry.get("Tasks")
    assert spec.kind == "text"


def test_view_kind_accessor():
    drv = _make_driver()
    assert drv.view_kind("Tasks") == "source"
    assert drv.view_kind("Inbox") == "gui_inbox"
    assert drv.view_kind("3D") == "3d"
    assert drv.view_kind("Logs") == "text"
    assert drv.view_kind("Nonexistent") is None


def test_archived_views_accessor():
    drv = _make_driver()
    assert drv.archived_views() == []
    drv.hold_ctrl()
    drv.ctrl_click("Quarantine")
    assert "Quarantine" in drv.archived_views()


def test_restore_view_explicit_call():
    drv = _make_driver()
    drv.hold_ctrl()
    drv.ctrl_click("Ideas")
    assert "Ideas" not in drv.list_views()
    assert drv.restore_view("Ideas") is True
    assert "Ideas" in drv.list_views()


# ---------------------------------------------------------------------------
# items_for_tab handles the text kind.
# ---------------------------------------------------------------------------


def test_items_for_text_view_renders_logs():
    """The Logs view streams ``engine.errors`` as one item per error.
    With no errors, a synthetic placeholder row is returned."""
    drv = _make_driver()
    items = drv.items_for_tab("Logs")
    assert len(items) >= 1
    assert items[0]["actions"] == ["expand"]


def test_items_for_text_view_with_errors():
    drv = _make_driver()
    drv.shell.engine.errors.extend(["err A", "err B", "err C"])
    items = drv.items_for_tab("Logs")
    assert len(items) == 3
    assert items[0]["title"] == "err A"


def test_items_from_text_view_generic_body():
    """For non-Logs text views, the spec's text_body becomes the one row."""

    class StubEngine:
        errors = []

    spec = ViewSpec(name="Help", kind="text", text_body="Help body")
    items = items_from_text_view(spec, StubEngine())
    assert len(items) == 1
    assert items[0]["body"] == "Help body"


# ---------------------------------------------------------------------------
# read_state surfaces the SPEC-067 view registry.
# ---------------------------------------------------------------------------


def test_read_state_includes_view_fields():
    drv = _make_driver()
    state = drv.read_state()
    for key in ("visible_views", "archived_views", "current_view"):
        assert key in state


def test_read_state_visible_views_matches_registry():
    drv = _make_driver()
    state = drv.read_state()
    assert state["visible_views"] == drv.shell.view_registry.names()
    assert state["archived_views"] == drv.shell.view_registry.archived_names()


# ---------------------------------------------------------------------------
# text-API ``set-view`` command (via dispatch_command).
# ---------------------------------------------------------------------------


def test_text_api_set_view_with_attached_registry():
    """The text command must find the registry on engine.view_registry
    + the gui_shell on engine.gui_shell and route the switch."""
    from tools.text_test import dispatch_command

    drv = _make_driver()
    msg, _ = dispatch_command(drv.shell.engine, "set-view Inbox")
    assert msg.startswith("OK:")
    assert drv.current_view() == "Inbox"


def test_text_api_set_view_unknown_returns_err():
    from tools.text_test import dispatch_command

    drv = _make_driver()
    msg, _ = dispatch_command(drv.shell.engine, "set-view Nonexistent")
    assert msg.startswith("ERR:")
    assert "unknown view" in msg


def test_text_api_set_view_no_arg_reports_current():
    from tools.text_test import dispatch_command

    drv = _make_driver()
    drv.set_view("Wishlist")
    msg, _ = dispatch_command(drv.shell.engine, "set-view")
    assert "Wishlist" in msg
    assert "available views" in msg


def test_text_api_list_views():
    from tools.text_test import dispatch_command

    drv = _make_driver()
    msg, _ = dispatch_command(drv.shell.engine, "list-views")
    assert "Tasks" in msg
    assert "Logs" in msg


def test_text_api_set_view_without_registry_errors():
    """Without an attached registry the command must report cleanly,
    not crash."""
    from engine.core import Engine
    from tools.text_test import dispatch_command

    e = Engine(root_dir=Path("."))
    msg, _ = dispatch_command(e, "set-view Whatever")
    assert msg.startswith("ERR")


# ---------------------------------------------------------------------------
# Reversibility cycle for set_view — analogous to set_mode cycles.
# ---------------------------------------------------------------------------


def test_set_view_cycle_reversibility():
    """Switching between views many times must leave the registry
    state stable (no leaks, no drift)."""
    drv = _make_driver()
    initial_visible = list(drv.list_views())
    for _ in range(20):
        drv.set_view("Ideas")
        drv.set_view("Tasks")
        drv.set_view("3D")
        drv.set_view("Logs")
        drv.set_view("Tasks")
    assert drv.current_view() == "Tasks"
    assert drv.list_views() == initial_visible


def test_archive_then_restore_reversibility():
    """Archive + restore over many cycles preserves registry order."""
    drv = _make_driver()
    initial_order = drv.list_views()
    drv.hold_ctrl()
    for _ in range(10):
        drv.ctrl_click("Quarantine")
        drv.restore_view("Quarantine")
    assert drv.list_views() == initial_order


# ---------------------------------------------------------------------------
# Archive integration: legacy mirrors stay in sync with the registry.
# ---------------------------------------------------------------------------


def test_archive_updates_legacy_mirrors():
    """The shell's ``_tab_order`` and ``_tabs`` are derived from the
    registry; archiving must rebuild both."""
    drv = _make_driver()
    drv.hold_ctrl()
    drv.ctrl_click("Wishlist")
    assert "Wishlist" not in drv.shell._tab_order
    tab_names = [name for name, _, _ in drv.shell._tabs]
    assert "Wishlist" not in tab_names


def test_register_view_updates_legacy_mirrors():
    """Registering a new view at runtime must surface it in the
    legacy mirrors so existing renderers pick it up."""
    drv = _make_driver()
    drv.register_view(ViewSpec(name="Extra", kind="gui_inbox", description="x"))
    assert "Extra" in drv.shell._tab_order
    tab_names = [name for name, _, _ in drv.shell._tabs]
    assert "Extra" in tab_names
    assert drv.shell._tab_help.get("Extra") == "x"
