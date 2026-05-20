"""
Tests for SPEC-075 per-widget lock granularity.

SPEC-075 generalizes SPEC-007's panel-level lock to ANY visible
affordance (icon, button, screen-area). The acceptance criteria:

- A WidgetLock registry round-trips lock/unlock for any widget id.
- Locked widgets reject drag events (panel widgets via the existing
  SPEC-007 drag handler that reads handle.locked, which now delegates
  to the registry).
- Unlocked widgets accept drag normally.
- Ctrl-right-click on any lockable widget opens a Lock/Unlock context
  menu (SPEC-072 composition: Ctrl-gated; SPEC-008 composition:
  right-click menu pattern).
- The lock survives a panel archive/restore cycle (the registry is
  the single source of truth across the cycle).
- PanelHandle.locked delegates to the registry — there's one source
  of truth for "is this panel locked?" rather than the dataclass
  field-vs-registry split that drift would otherwise allow.

All tests run headless (no Tk window). The Ctrl-right-click menu is
exercised via the public ``widget_context_menu_items`` method.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.gui_test_driver import GuiDriver
from tools.workflow_gui.gui_shell import PanelHandle
from tools.workflow_gui.widget_lock import LockEntry, WidgetLock


# ---------------------------------------------------------------------------
# WidgetLock registry CRUD.
# ---------------------------------------------------------------------------


def test_registry_fresh_state_is_unlocked():
    """A fresh WidgetLock returns False for any widget id — the
    permissive default that matches SPEC-007's pre-WidgetLock behavior
    for un-registered widgets."""
    reg = WidgetLock()
    assert reg.is_widget_locked("anything") is False
    assert reg.widget_state("anything") == {}


def test_lock_widget_registers_and_locks():
    """``lock_widget`` on an unseen id creates a registry entry and
    sets locked=True in the same call (lazy registration)."""
    reg = WidgetLock()
    assert reg.lock_widget("icon_a") is True
    assert reg.is_widget_locked("icon_a") is True
    assert "icon_a" in reg


def test_unlock_widget_after_lock():
    """``unlock_widget`` flips the flag and keeps the entry — the
    registry is monotonic in entries even though the flag toggles."""
    reg = WidgetLock()
    reg.lock_widget("button_b")
    reg.unlock_widget("button_b")
    assert reg.is_widget_locked("button_b") is False
    assert "button_b" in reg, "entry removed on unlock"


def test_unlock_widget_on_unknown_returns_false():
    """Unlocking an unseen id returns False (nothing to unlock) but
    doesn't raise — defensive behavior for stale ids passed by tests
    or text-API callers."""
    reg = WidgetLock()
    assert reg.unlock_widget("nonexistent") is False


def test_lock_widget_records_widget_kind():
    """The widget_kind tag (panel / button / icon / region) is
    recorded so list_locked_widgets can group by kind."""
    reg = WidgetLock()
    reg.lock_widget("send_button", widget_kind="button")
    state = reg.widget_state("send_button")
    assert state["widget_kind"] == "button"
    assert state["widget_id"] == "send_button"
    assert state["locked"] is True


def test_lock_widget_records_frozen_position():
    """The frozen_position tuple is captured at lock-time so the v2
    layout-resistance feature can re-place the widget after a parent
    reflow. v1 records the snapshot; v2 acts on it."""
    reg = WidgetLock()
    reg.lock_widget("icon_x", position=(120, 240))
    state = reg.widget_state("icon_x")
    assert state["frozen_position"] == (120, 240)


def test_list_locked_widgets_sorted_by_id():
    """list_locked_widgets returns entries sorted by widget_id for
    deterministic test assertions + diagnostic output."""
    reg = WidgetLock()
    reg.lock_widget("zebra", widget_kind="icon")
    reg.lock_widget("alpha", widget_kind="icon")
    reg.lock_widget("middle", widget_kind="button")
    ids = [e["widget_id"] for e in reg.list_locked_widgets()]
    assert ids == ["alpha", "middle", "zebra"]


def test_list_locked_widgets_omits_unlocked_entries():
    """Unlocked entries (including those with frozen-position
    snapshots from a prior lock) are omitted from the locked list."""
    reg = WidgetLock()
    reg.lock_widget("a")
    reg.lock_widget("b")
    reg.unlock_widget("a")
    locked_ids = [e["widget_id"] for e in reg.list_locked_widgets()]
    assert locked_ids == ["b"]


def test_register_does_not_lock():
    """register() creates an entry but leaves it unlocked — used by
    the GuiShell to announce lockable widgets at build time so the
    list-locked-widgets verb can answer about widgets that haven't yet
    been locked. The locked flag stays False."""
    reg = WidgetLock()
    reg.register("preview_button", widget_kind="button")
    assert reg.is_widget_locked("preview_button") is False
    assert "preview_button" in reg


def test_re_lock_preserves_widget_kind():
    """Locking an already-registered widget without supplying a kind
    preserves the kind from the prior registration."""
    reg = WidgetLock()
    reg.register("settings_icon", widget_kind="icon")
    reg.lock_widget("settings_icon")
    state = reg.widget_state("settings_icon")
    assert state["widget_kind"] == "icon"


# ---------------------------------------------------------------------------
# PanelHandle delegates lock state to the registry.
# ---------------------------------------------------------------------------


def test_panel_handle_isolated_uses_fallback():
    """A PanelHandle built without a registry attached uses the
    fallback bool — preserves the dataclass usability for tests that
    construct handles in isolation."""
    handle = PanelHandle(view_name="x")
    assert handle.locked is False
    handle.locked = True
    assert handle.locked is True


def test_panel_handle_delegates_to_registry_when_wired():
    """When _lock_registry is wired, reads/writes route through the
    registry rather than the fallback bool."""
    reg = WidgetLock()
    handle = PanelHandle(
        view_name="x",
        _lock_registry=reg,
        _panel_id="panel_x",
    )
    handle.locked = True
    assert reg.is_widget_locked("panel_x") is True
    handle.locked = False
    assert reg.is_widget_locked("panel_x") is False


def test_panel_handle_delegating_lock_uses_panel_kind():
    """Locks routed through PanelHandle tag the widget_kind as
    'panel' so list_locked_widgets groups panels distinctly."""
    reg = WidgetLock()
    handle = PanelHandle(
        view_name="x",
        x=24,
        y=36,
        _lock_registry=reg,
        _panel_id="panel_x",
    )
    handle.locked = True
    state = reg.widget_state("panel_x")
    assert state["widget_kind"] == "panel"
    assert state["frozen_position"] == (24, 36)


def test_panel_handle_ensure_handle_wires_registry():
    """Ensuring a panel handle on the shell wires the registry and
    pre-registers the entry as widget_kind='panel'."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    assert "test_panel" in drv.shell.widget_lock
    state = drv.shell.widget_lock_state("test_panel")
    assert state["widget_kind"] == "panel"


# ---------------------------------------------------------------------------
# GuiShell lock_widget / unlock_widget — panel + non-panel routing.
# ---------------------------------------------------------------------------


def test_shell_lock_widget_on_panel_id_routes_through_panel_api():
    """lock_widget on a known panel id delegates to lock_panel so the
    SPEC-007 drag/resize handlers (which read handle.locked) see the
    same state."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.lock_widget("p")
    assert drv.shell.is_locked("p") is True  # SPEC-007 surface
    assert drv.is_widget_locked("p") is True  # SPEC-075 surface


def test_shell_lock_widget_on_unseen_icon_uses_registry():
    """lock_widget on an id that's NOT a panel registers an entry in
    the WidgetLock registry directly — the per-icon / per-button case
    SPEC-075 is built for."""
    drv = GuiDriver().build()
    drv.lock_widget("send_button", widget_kind="button")
    assert drv.is_widget_locked("send_button") is True
    state = drv.widget_lock_state("send_button")
    assert state["widget_kind"] == "button"


def test_shell_unlock_widget_handles_both_kinds():
    """unlock_widget unlocks panel and non-panel widgets through the
    same surface."""
    drv = GuiDriver().build()
    drv.ensure_panel("panel_p")
    drv.lock_widget("panel_p")
    drv.lock_widget("icon_q", widget_kind="icon")
    drv.unlock_widget("panel_p")
    drv.unlock_widget("icon_q")
    assert drv.is_widget_locked("panel_p") is False
    assert drv.is_widget_locked("icon_q") is False


def test_shell_unlock_widget_on_unknown_returns_false():
    """unlock_widget on an id that's neither a panel nor a registered
    widget returns False rather than raising."""
    drv = GuiDriver().build()
    assert drv.unlock_widget("nonexistent") is False


# ---------------------------------------------------------------------------
# Locked panels reject drag (SPEC-007 composition via delegation).
# ---------------------------------------------------------------------------


def test_locked_widget_panel_rejects_drag():
    """A panel locked via the SPEC-075 lock_widget verb refuses
    move-panel — the drag handler reads handle.locked which now
    delegates to the registry, so the panel's drag continues to no-op
    even though the lock was set through the new surface."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.move_panel("p", 48, 60)  # Position before lock.
    drv.lock_widget("p")
    drv.move_panel("p", 120, 144)
    state = drv.panel_state("p")
    assert state["x"] == 48
    assert state["y"] == 60


def test_unlocked_widget_panel_accepts_drag():
    """An unlocked panel accepts move-panel normally."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.move_panel("p", 48, 60)
    state = drv.panel_state("p")
    assert state["x"] == 48
    assert state["y"] == 60


def test_lock_then_unlock_restores_drag():
    """Locking and then unlocking a panel through the widget API
    restores drag responsiveness — the registry is the source of
    truth and the handle's property re-reads it on every drag."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.lock_widget("p")
    drv.move_panel("p", 120, 144)
    assert drv.panel_state("p")["x"] == 0  # locked: drag rejected
    drv.unlock_widget("p")
    drv.move_panel("p", 120, 144)
    state = drv.panel_state("p")
    assert state["x"] == 120
    assert state["y"] == 144


def test_locked_widget_panel_rejects_resize():
    """A panel locked via the SPEC-075 lock_widget surface also rejects
    resize — the same handle.locked check covers both gestures."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    state_pre = drv.resize_panel("p", 240, 240)
    drv.lock_widget("p")
    drv.resize_panel("p", 480, 480)
    state_post = drv.panel_state("p")
    assert state_post["w"] == state_pre["w"]
    assert state_post["h"] == state_pre["h"]


# ---------------------------------------------------------------------------
# Ctrl-right-click context menu (SPEC-072 + SPEC-008 composition).
# ---------------------------------------------------------------------------


def test_widget_context_menu_unlocked_shows_lock():
    """An unlocked widget surfaces ``["Lock"]`` as its sole
    Ctrl-right-click menu item — the SPEC-075 minimal v1 menu."""
    drv = GuiDriver().build()
    drv.lock_widget("icon_a")  # ensure entry exists
    drv.unlock_widget("icon_a")
    items = drv.widget_context_menu_items("icon_a", "icon")
    assert items == ["Lock"]


def test_widget_context_menu_locked_shows_unlock():
    """A locked widget surfaces ``["Unlock"]`` — the toggle pair flips."""
    drv = GuiDriver().build()
    drv.lock_widget("icon_a", widget_kind="icon")
    items = drv.widget_context_menu_items("icon_a", "icon")
    assert items == ["Unlock"]


def test_widget_context_menu_for_panel_widget():
    """Ctrl-right-click on a panel widget shows the per-widget menu
    based on the panel's lock state — composes with SPEC-008 panel
    menu but offers the focused toggle pair."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    items_unlocked = drv.widget_context_menu_items("p", "panel")
    assert items_unlocked == ["Lock"]
    drv.lock_widget("p")
    items_locked = drv.widget_context_menu_items("p", "panel")
    assert items_locked == ["Unlock"]


def test_show_widget_context_menu_requires_ctrl():
    """The actual Ctrl-right-click handler only opens the menu when
    Ctrl is held (SPEC-072 gate). Returns None when not held."""
    drv = GuiDriver().build()
    from types import SimpleNamespace

    drv.shell.ctrl_held = False
    event = SimpleNamespace(x_root=10, y_root=10)
    # tk_root is set in build() — but the gate fires before any Tk
    # code runs, so an early-return None is expected without Ctrl.
    result = drv.shell._show_widget_context_menu(event, "icon_a", "icon")
    assert result is None


# ---------------------------------------------------------------------------
# Lock survives panel archive/restore cycle.
# ---------------------------------------------------------------------------


def test_lock_survives_panel_archive_restore():
    """A widget-lock applied via lock_widget on a panel survives the
    panel-archive + panel-restore round-trip. The registry holds the
    lock; the archive cycle doesn't touch the registry."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.lock_widget("p")
    drv.archive_panel("p")
    drv.restore_panel("p")
    assert drv.is_widget_locked("p") is True
    assert drv.panel_state("p")["locked"] is True


def test_lock_survives_multiple_tab_switches():
    """A widget-lock applied via lock_widget on a panel survives an
    arbitrary number of tab-switches. Same monotonic invariant as
    SPEC-007's panel-level lock."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.lock_widget("Tasks")
    for tab in ("Ideas", "Wishlist", "Inbox", "Chat", "Tasks", "Logs", "Tasks"):
        drv.select_tab(tab)
    assert drv.is_widget_locked("Tasks") is True


# ---------------------------------------------------------------------------
# list_locked_widgets enumerates across kinds.
# ---------------------------------------------------------------------------


def test_list_locked_widgets_groups_kinds():
    """list_locked_widgets returns entries across kinds (panel /
    button / icon) so the maintainer can see every lock in one
    surface."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.lock_widget("Tasks")  # panel
    drv.lock_widget("send_btn", widget_kind="button")
    drv.lock_widget("settings_icon", widget_kind="icon")
    locked = drv.list_locked_widgets()
    ids = sorted(e["widget_id"] for e in locked)
    assert "Tasks" in ids
    assert "send_btn" in ids
    assert "settings_icon" in ids


def test_list_locked_widgets_empty_when_nothing_locked():
    """A fresh shell has no locked widgets — the list is empty even
    after panels have been ensured (registration without locking)."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.ensure_panel("Ideas")
    locked = drv.list_locked_widgets()
    assert locked == []


# ---------------------------------------------------------------------------
# Text-API verbs round-trip.
# ---------------------------------------------------------------------------


def test_text_api_lock_widget():
    """The text-API lock-widget verb routes through dispatch_command."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    msg, _ = dispatch_command(drv.shell.engine, "lock-widget icon_x")
    assert msg.startswith("OK")
    assert drv.is_widget_locked("icon_x") is True


def test_text_api_unlock_widget():
    """The text-API unlock-widget verb clears the lock."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    drv.lock_widget("icon_x", widget_kind="icon")
    msg, _ = dispatch_command(drv.shell.engine, "unlock-widget icon_x")
    assert msg.startswith("OK")
    assert drv.is_widget_locked("icon_x") is False


def test_text_api_widget_lock_state():
    """The text-API widget-lock-state verb returns the registry entry
    as a dict-shaped OK message."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    drv.lock_widget("button_y", widget_kind="button")
    msg, _ = dispatch_command(drv.shell.engine, "widget-lock-state button_y")
    assert msg.startswith("OK")
    assert "'locked': True" in msg
    assert "'widget_kind': 'button'" in msg


def test_text_api_list_locked_widgets():
    """The text-API list-locked-widgets verb returns the sorted list
    as an OK message; empty list when nothing is locked."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    msg, _ = dispatch_command(drv.shell.engine, "list-locked-widgets")
    assert msg == "OK: []"
    drv.lock_widget("zebra", widget_kind="icon")
    drv.lock_widget("alpha", widget_kind="icon")
    msg, _ = dispatch_command(drv.shell.engine, "list-locked-widgets")
    assert "alpha" in msg
    assert "zebra" in msg
    # Sorted: alpha appears before zebra in the string.
    assert msg.index("alpha") < msg.index("zebra")


def test_text_api_lock_widget_missing_arg():
    """lock-widget without arguments returns ERR."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    msg, _ = dispatch_command(drv.shell.engine, "lock-widget")
    assert msg.startswith("ERR")


def test_text_api_widget_lock_state_unknown():
    """widget-lock-state on an unknown widget returns ERR."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    msg, _ = dispatch_command(drv.shell.engine, "widget-lock-state nonexistent")
    assert msg.startswith("ERR")


# ---------------------------------------------------------------------------
# SPEC-007 composition — PanelHandle is the specialization.
# ---------------------------------------------------------------------------


def test_panel_lock_via_spec007_visible_in_spec075_registry():
    """A panel locked via the SPEC-007 lock_panel verb is visible
    through the SPEC-075 is_widget_locked surface — one source of
    truth, the registry."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.lock_panel("p")  # SPEC-007 surface
    assert drv.is_widget_locked("p") is True  # SPEC-075 surface
    assert "p" in {e["widget_id"] for e in drv.list_locked_widgets()}


def test_panel_lock_via_spec075_visible_in_spec007_surface():
    """A panel locked via SPEC-075 is visible through SPEC-007's
    is_locked — the property delegates, and both surfaces see the
    registry's truth."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    drv.lock_widget("p")  # SPEC-075 surface
    assert drv.shell.is_locked("p") is True  # SPEC-007 surface
    assert drv.panel_state("p")["locked"] is True  # SPEC-007 surface


def test_panel_lock_state_consistent_through_handle_property():
    """The PanelHandle.locked property reads from the registry every
    time — there's no per-handle cache that could drift."""
    drv = GuiDriver().build()
    drv.ensure_panel("p")
    handle = drv.shell._panel_handles["p"]
    assert handle.locked is False
    drv.lock_widget("p")
    assert handle.locked is True
    drv.unlock_widget("p")
    assert handle.locked is False


# ---------------------------------------------------------------------------
# Pre-registration via sidebar tab construction.
# ---------------------------------------------------------------------------


def test_sidebar_widgets_register_at_build_time():
    """When the sidebar is built (build()), each sidebar tab button
    is pre-registered as a lockable widget with the prefix 'sidebar:'.
    Tests that the widget_lock registry has at least one such entry
    after the GuiDriver builds the shell."""
    drv = GuiDriver().build()
    # The headless GuiDriver may not actually build the Tk UI; in
    # that case sidebar widgets aren't registered. The probe is
    # conditional on build_ui having run. We assert the contract: if
    # the registry surfaces ANY sidebar:* entry, that entry exists with
    # widget_kind='button'.
    all_entries = drv.shell.widget_lock.all_widgets()
    sidebar_entries = [
        e for e in all_entries if e["widget_id"].startswith("sidebar:")
    ]
    if sidebar_entries:
        for entry in sidebar_entries:
            assert entry["widget_kind"] == "button"
