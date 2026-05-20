"""
Tests for SPEC-007 lock-state persistence.

The design doc placed lock state on the PanelHandle (per-instance UI
position) rather than on the ViewSpec (declarative shape of a view).
The "ViewSpec round-trip" clause in the test obligation is "if
applicable" — and the applicability is: lock state must NOT leak into
the ViewSpec serialization, AND it must persist through every
GUI-state operation that legitimately preserves the panel layout.

The tests under this file:

- Lock state survives a tab-switch round-trip (the handle outlives
  a switch away and back).
- Lock state survives the SPEC-067 archive/restore cycle (so the
  maintainer doesn't have to re-lock a panel that came back).
- Lock state does NOT bleed into ViewSpec — ViewSpec is frozen, so
  the per-panel lock cannot mutate the declarative shape.
- The ViewSpec → tuple → re-register round-trip preserves the
  immutable view fields and ignores any per-instance lock.
- Lock state surfaces in ``read_state()`` so tests + diagnostics can
  observe the per-panel locked flag.
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
from tools.workflow_gui.view_registry import (
    ViewRegistry,
    ViewSpec,
    default_view_registry,
)


# ---------------------------------------------------------------------------
# Lock state survives tab-switch round-trips.
# ---------------------------------------------------------------------------


def test_lock_state_survives_tab_switch():
    """Selecting a different tab and switching back doesn't reset the
    panel's locked state — the handle outlives select_tab."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.lock_panel("Tasks")
    drv.select_tab("Ideas")
    drv.select_tab("Tasks")
    assert drv.panel_state("Tasks")["locked"] is True


def test_lock_state_survives_multiple_switches():
    """Lock state is monotonically preserved across an arbitrary
    number of tab switches. The handle is the source of truth; the
    tab-switch never touches it."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.lock_panel("Tasks")
    for tab in ("Ideas", "Wishlist", "Inbox", "Chat", "Tasks", "Logs", "Tasks"):
        drv.select_tab(tab)
    assert drv.panel_state("Tasks")["locked"] is True


def test_unlock_state_also_survives_switches():
    """The same monotonic invariant applies to the unlocked state —
    a tab-switch never spuriously locks a panel."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    # Default unlocked.
    drv.select_tab("Ideas")
    drv.select_tab("Tasks")
    assert drv.panel_state("Tasks")["locked"] is False


# ---------------------------------------------------------------------------
# Lock state survives archive/restore cycles (SPEC-008 composition).
# ---------------------------------------------------------------------------


def test_lock_state_survives_archive_restore():
    """A locked panel that is archived stays locked when restored.
    The design doc's resolution: lock is preserved through archive/
    restore so the maintainer doesn't re-lock on restore."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.archive_panel("test_panel")
    drv.restore_panel("test_panel")
    assert drv.panel_state("test_panel")["locked"] is True


def test_lock_state_survives_archive_alone():
    """Even before restore, the archived locked panel reports
    locked=True via panel_state — the handle is the source of truth."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.archive_panel("test_panel")
    state = drv.panel_state("test_panel")
    assert state["locked"] is True
    assert state["archived"] is True


def test_unlock_panel_while_archived():
    """The right-click 'Unlock' item is enabled on archived rows
    (design doc §9 risk-4), so the maintainer can unlock without
    restoring first."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.archive_panel("test_panel")
    drv.unlock_panel("test_panel")
    state = drv.panel_state("test_panel")
    assert state["locked"] is False
    assert state["archived"] is True  # archive flag unaffected


# ---------------------------------------------------------------------------
# ViewSpec round-trip — lock does NOT bleed into ViewSpec.
# ---------------------------------------------------------------------------


def test_viewspec_is_frozen():
    """ViewSpec is a frozen dataclass — attempting to set a `locked`
    attribute raises. This catches a future drift where someone tries
    to stash per-panel state on the declarative ViewSpec."""
    spec = ViewSpec(name="Test", kind="text", description="", text_body="x")
    with pytest.raises(Exception):
        spec.locked = True  # type: ignore[attr-defined]


def test_viewspec_round_trip_preserves_declarative_fields():
    """Construct → re-register → re-fetch should produce a spec with
    identical declarative fields. The registry preserves the spec by
    reference; the round-trip is a structural identity check."""
    reg = ViewRegistry()
    original = ViewSpec(
        name="RoundTrip",
        kind="text",
        description="round-trip test view",
        text_body="some body",
    )
    reg.register(original)
    fetched = reg.get("RoundTrip")
    assert fetched is not None
    assert fetched.name == original.name
    assert fetched.kind == original.kind
    assert fetched.description == original.description
    assert fetched.text_body == original.text_body


def test_viewspec_round_trip_does_not_carry_panel_state():
    """ViewSpec has no lock/x/y/w/h fields — those live on the
    PanelHandle. The serialization shape is intentionally narrower
    than the runtime state."""
    spec = ViewSpec(name="Test", kind="text", description="", text_body="x")
    for field_name in ("locked", "x", "y", "w", "h", "archived"):
        assert not hasattr(spec, field_name), (
            f"ViewSpec has unexpected per-panel field {field_name!r}"
        )


def test_panel_handle_is_unfrozen():
    """PanelHandle is mutable because it tracks UI state (every drag
    mutates x/y; every lock toggles locked). Frozen would force a
    rebuild-everything-on-move pattern that doesn't fit the workload."""
    handle = PanelHandle(view_name="x")
    handle.x = 24
    handle.locked = True
    handle.archived = True
    assert handle.x == 24
    assert handle.locked is True
    assert handle.archived is True


def test_handle_round_trip_through_panel_state_dict():
    """The dict produced by panel_state contains every field on the
    PanelHandle so a future serializer (e.g. the design doc's
    state/workflow/gui_layout.json persistence) can reconstruct the
    handle from the dict alone.

    This test asserts the dict shape — not the persistence layer
    itself (the JSON write is v3-postponed per the design doc)."""
    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    drv.lock_panel("test_panel")
    drv.move_panel("test_panel", 48, 60)
    state = drv.panel_state("test_panel")
    expected_keys = {
        "panel_id", "view_name", "x", "y", "w", "h",
        "locked", "archived",
    }
    assert set(state.keys()) == expected_keys


# ---------------------------------------------------------------------------
# read_state surface — lock state is observable from the driver.
# ---------------------------------------------------------------------------


def test_read_state_surfaces_lock_state_per_panel():
    """read_state's panel_handles dict carries the locked flag for
    every panel so a caller can verify lock state without poking shell
    internals."""
    drv = GuiDriver().build()
    drv.ensure_panel("a")
    drv.ensure_panel("b")
    drv.lock_panel("a")
    state = drv.read_state()
    assert state["panel_handles"]["a"]["locked"] is True
    assert state["panel_handles"]["b"]["locked"] is False


def test_lock_state_text_api_round_trip():
    """The text-API lock-panel + panel-state commands round-trip the
    lock flag end-to-end."""
    from tools.text_test import dispatch_command

    drv = GuiDriver().build()
    drv.ensure_panel("test_panel")
    msg, _ = dispatch_command(drv.shell.engine, "lock-panel test_panel")
    assert msg.startswith("OK")
    msg, _ = dispatch_command(drv.shell.engine, "panel-state test_panel")
    assert "'locked': True" in msg
    msg, _ = dispatch_command(drv.shell.engine, "unlock-panel test_panel")
    assert msg.startswith("OK")
    msg, _ = dispatch_command(drv.shell.engine, "panel-state test_panel")
    assert "'locked': False" in msg


# ---------------------------------------------------------------------------
# Lock state per-instance: two panels of the same view are independent.
# ---------------------------------------------------------------------------


def test_locks_are_per_panel_not_per_view():
    """The design doc commits to per-instance lock state: two panels
    of the same view (e.g. paste-as-duplicate from SPEC-073) can lock
    independently."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks_1")
    drv.ensure_panel("Tasks_2")
    drv.lock_panel("Tasks_1")
    assert drv.panel_state("Tasks_1")["locked"] is True
    assert drv.panel_state("Tasks_2")["locked"] is False


def test_lock_does_not_affect_other_panels_position():
    """Locking one panel doesn't impede another panel's drag/resize."""
    drv = GuiDriver().build()
    drv.ensure_panel("a")
    drv.ensure_panel("b")
    drv.lock_panel("a")
    drv.move_panel("b", 48, 60)
    assert drv.panel_state("b")["x"] == 48
    assert drv.panel_state("b")["y"] == 60


def test_view_registry_unaware_of_lock_state():
    """The ViewRegistry's archive list doesn't reflect per-panel lock
    state. ViewRegistry is the declarative view layer; locks are
    runtime UI."""
    drv = GuiDriver().build()
    drv.ensure_panel("Tasks")
    drv.lock_panel("Tasks")
    # The registry still considers Tasks visible (unchanged by lock).
    assert "Tasks" in drv.shell.view_registry.names()
    assert "Tasks" not in drv.shell.view_registry.archived_names()
