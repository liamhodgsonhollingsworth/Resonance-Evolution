"""
Tests for the SPEC-008 right-click context menu + Archive view.

The acceptance criteria:

- Right-click on a panel header opens a context menu with the items
  the design specifies (Archive, Restore [disabled when not archived],
  Copy, Paste, Lock/Unlock, Properties).
- Selecting Archive routes through ``shell.archive_panel`` which
  composes with the SPEC-067 ViewRegistry — the matching view also
  archives so the sidebar tab disappears.
- The Archive view in ``default_view_registry()`` surfaces archived
  panels and views, each with a Restore action.
- Selecting Restore on an Archive-view row brings the target back.

All tests run headless (no Tk window required). The right-click
gesture is exercised via the ``context_menu_items()`` public method
which returns the labels that would appear in the popup menu.
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
from tools.workflow_gui.view_registry import (
    ViewRegistry,
    ViewSpec,
    default_view_registry,
)


# ---------------------------------------------------------------------------
# Context-menu item construction.
# ---------------------------------------------------------------------------


def test_context_menu_panel_default_items():
    """A fresh (un-archived, un-locked) panel target produces the
    canonical 7-item menu: Archive panel / Restore (disabled) / Copy
    / Paste / Lock panel / Properties."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    items = drv.shell.context_menu_items("panel", "test_panel")
    assert items == [
        "Archive panel",
        "Restore",
        "Copy module",
        "Paste module",
        "Lock panel",
        "Properties",
    ]


def test_context_menu_locked_panel_shows_unlock():
    """A locked panel surfaces 'Unlock panel' instead of 'Lock panel'."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    items = drv.shell.context_menu_items("panel", "test_panel")
    assert "Unlock panel" in items
    assert "Lock panel" not in items


def test_context_menu_archived_panel_shows_restore_panel():
    """An archived panel surfaces 'Restore panel' enabled."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.archive_panel("test_panel")
    items = drv.shell.context_menu_items("panel", "test_panel")
    assert "Restore panel" in items
    assert "Restore" not in items  # the disabled placeholder is gone


def test_context_menu_sidebar_target_archive_view():
    """Right-click on a sidebar tab shows 'Archive view' rather than
    'Archive panel'."""
    drv = GuiDriver().build()
    items = drv.shell.context_menu_items("sidebar", "Tasks")
    assert "Archive view" in items
    assert "Archive panel" not in items


def test_context_menu_sidebar_archived_view_shows_restore_view():
    """An archived sidebar view shows 'Restore view' enabled."""
    drv = GuiDriver().build()
    drv.shell.view_registry.archive("Tasks")
    items = drv.shell.context_menu_items("sidebar", "Tasks")
    assert "Restore view" in items


def test_context_menu_unknown_target_kind_disables_archive():
    """An unknown target_kind still produces a menu, but the Archive
    item is the disabled placeholder, not the active Archive label."""
    drv = GuiDriver().build()
    items = drv.shell.context_menu_items("row", "unknown")
    # The unknown kind path returns "Archive" (the disabled label).
    assert "Archive" in items


# ---------------------------------------------------------------------------
# Archive flow — right-click → archive_panel → SPEC-067 composition.
# ---------------------------------------------------------------------------


def test_archive_panel_composes_with_view_registry():
    """Archiving a panel that corresponds to a view also archives the
    view in the SPEC-067 registry — the sidebar tab disappears."""
    drv = GuiDriver().build()
    # Use a real view name so the registry has a matching spec.
    drv.shell._ensure_panel_handle("Tasks")
    drv.archive_panel("Tasks")
    assert "Tasks" in drv.shell.view_registry.archived_names()


def test_archive_panel_preserves_handle_state():
    """The handle's (x, y, w, h, locked) survives an archive cycle so
    a restore brings the panel back at its prior position. All values
    are grid-aligned so snap_to_grid is a no-op."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 96, 120)
    drv.resize_panel("test_panel", 600, 396)  # 396 = 33*12, grid-aligned
    drv.lock_panel("test_panel")
    drv.archive_panel("test_panel")
    state = drv.panel_state("test_panel")
    assert state["x"] == 96
    assert state["y"] == 120
    assert state["w"] == 600
    assert state["h"] == 396
    assert state["locked"] is True
    assert state["archived"] is True


def test_archive_panel_non_view_target_is_local_only():
    """Archiving a panel whose name isn't a registered view affects
    only the panel handle — no view archive composition."""
    drv = GuiDriver().build()
    drv.ensure_panel("standalone_panel")
    drv.archive_panel("standalone_panel")
    state = drv.panel_state("standalone_panel")
    assert state["archived"] is True
    assert "standalone_panel" not in drv.shell.view_registry.archived_names()


def test_archive_panel_missing_returns_false():
    """archive_panel on an unknown panel id returns False rather than
    silently creating + archiving a handle."""
    drv = GuiDriver().build()
    assert drv.archive_panel("never_existed") is False


# ---------------------------------------------------------------------------
# Restore flow — right-click → restore_panel → handle state survives.
# ---------------------------------------------------------------------------


def test_restore_panel_brings_back_at_prior_position():
    """After an archive/restore cycle, the panel handle's position is
    identical to the pre-archive snapshot."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.move_panel("test_panel", 48, 72)
    drv.resize_panel("test_panel", 540, 348)
    pre = drv.panel_state("test_panel")
    drv.archive_panel("test_panel")
    drv.restore_panel("test_panel")
    post = drv.panel_state("test_panel")
    assert post["x"] == pre["x"]
    assert post["y"] == pre["y"]
    assert post["w"] == pre["w"]
    assert post["h"] == pre["h"]
    assert post["archived"] is False


def test_restore_panel_clears_archived_flag():
    """Restore flips the archived flag back to False on the handle."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.archive_panel("test_panel")
    drv.restore_panel("test_panel")
    state = drv.panel_state("test_panel")
    assert state["archived"] is False


def test_restore_panel_also_restores_view():
    """Restoring a panel that backs an archived view also restores the
    view in the registry — the sidebar tab reappears."""
    drv = GuiDriver().build()
    drv.shell._ensure_panel_handle("Tasks")
    drv.archive_panel("Tasks")  # archives both panel + view
    assert "Tasks" in drv.shell.view_registry.archived_names()
    drv.restore_panel("Tasks")
    assert "Tasks" not in drv.shell.view_registry.archived_names()
    assert "Tasks" in drv.shell.view_registry.names()


# ---------------------------------------------------------------------------
# Archive view — surfacing archived panels + views.
# ---------------------------------------------------------------------------


def test_archive_view_registered_in_default_registry():
    """default_view_registry() includes an Archive view (SPEC-008)."""
    reg = default_view_registry()
    spec = reg.get("Archive")
    assert spec is not None
    assert spec.kind == "dynamic"
    assert spec.items_provider is not None


def test_archive_view_lists_archived_views():
    """The Archive view's items provider returns one row per archived
    view."""
    drv = GuiDriver().build()
    drv.shell.view_registry.archive("Tasks")
    drv.shell.view_registry.archive("Ideas")
    items = drv.items_for_tab("Archive")
    ids = [it["id"] for it in items]
    assert "view:Tasks" in ids
    assert "view:Ideas" in ids


def test_archive_view_lists_archived_panels():
    """Archived panels also appear as rows."""
    drv = GuiDriver().build()
    drv.ensure_panel("custom_panel")
    drv.archive_panel("custom_panel")
    items = drv.items_for_tab("Archive")
    ids = [it["id"] for it in items]
    assert "panel:custom_panel" in ids


def test_archive_view_empty_when_nothing_archived():
    """With nothing archived, the Archive view shows a single
    placeholder row explaining how to archive."""
    drv = GuiDriver().build()
    items = drv.items_for_tab("Archive")
    assert len(items) == 1
    assert items[0]["id"] == "archive-empty"


def test_archive_view_row_has_restore_action():
    """Each archived row carries a 'restore' action so right-click
    Restore actions through the standard _on_action dispatch."""
    drv = GuiDriver().build()
    drv.shell.view_registry.archive("Tasks")
    items = drv.items_for_tab("Archive")
    archived_row = next((it for it in items if it["id"] == "view:Tasks"), None)
    assert archived_row is not None
    assert "restore" in archived_row.get("actions", [])


def test_archive_view_row_meta_carries_target_kind():
    """The meta dict on each row carries target_kind + target_id so
    _on_action dispatch knows which restore method to call."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.archive_panel("test_panel")
    items = drv.items_for_tab("Archive")
    row = next((it for it in items if it["id"] == "panel:test_panel"), None)
    assert row is not None
    assert row["meta"]["target_kind"] == "panel"
    assert row["meta"]["target_id"] == "test_panel"


def test_restore_action_dispatch_unarchives_view():
    """Dispatching the 'restore' action on an archived view row
    routes through _on_action and brings the view back."""
    drv = GuiDriver().build()
    drv.shell.view_registry.archive("Tasks")
    items = drv.items_for_tab("Archive")
    archived_row = next(it for it in items if it["id"] == "view:Tasks")
    drv.shell._on_action("restore", archived_row)
    assert "Tasks" not in drv.shell.view_registry.archived_names()


def test_restore_action_dispatch_unarchives_panel():
    """Dispatching the 'restore' action on an archived panel row
    routes through _on_action and brings the panel back."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.archive_panel("test_panel")
    items = drv.items_for_tab("Archive")
    archived_row = next(it for it in items if it["id"] == "panel:test_panel")
    drv.shell._on_action("restore", archived_row)
    state = drv.panel_state("test_panel")
    assert state["archived"] is False


# ---------------------------------------------------------------------------
# Text-API surface for the archive flow.
# ---------------------------------------------------------------------------


def test_text_api_archive_panel_command():
    """The text-API archive-panel command routes through shell.
    archive_panel and returns OK."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    msg, _ = dispatch_command(drv.shell.engine, "archive-panel test_panel")
    assert msg.startswith("OK")
    assert drv.panel_state("test_panel")["archived"] is True


def test_text_api_restore_panel_command():
    """The text-API restore-panel command works against an archived
    panel."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.archive_panel("test_panel")
    msg, _ = dispatch_command(drv.shell.engine, "restore-panel test_panel")
    assert msg.startswith("OK")
    assert drv.panel_state("test_panel")["archived"] is False


def test_text_api_archive_panel_missing_returns_err():
    """archive-panel on an unknown panel id surfaces an ERR result."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    msg, _ = dispatch_command(drv.shell.engine, "archive-panel never_existed")
    assert msg.startswith("ERR")
