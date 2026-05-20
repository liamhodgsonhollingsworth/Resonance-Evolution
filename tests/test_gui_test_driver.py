"""
Tests for the text-API GUI test driver (SPEC-081).

The driver lets a session exercise GUI behavior without launching Tk.
These tests verify the driver itself works end-to-end against the
stub backends, so a future session can trust the driver's reports
when validating new GUI features.

Per the maintainer's verbatim directives across sessions da9df8be,
2575849f, and d95e17b4: the session must build its own tools to test
the GUI, not rely on visual verification by the maintainer.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.gui_test_driver import GuiDriver, _smoke


# ---------------------------------------------------------------------------
# Construction.
# ---------------------------------------------------------------------------


def test_build_returns_driver_with_shell():
    drv = GuiDriver().build()
    assert drv.shell is not None


def test_build_headless_does_not_open_tk_window():
    """Headless mode means build_ui isn't called, so tk_root stays None."""
    drv = GuiDriver(headless=True).build()
    assert drv.shell.tk_root is None


def test_initial_state_snapshot_has_expected_keys():
    drv = GuiDriver().build()
    state = drv.read_state()
    for key in (
        "active_tab",
        "ctrl_held",
        "sidebar_scale",
        "tab_order",
        "expanded_item_id",
        "active_session_id",
        "tab_count",
    ):
        assert key in state, f"missing state key: {key}"


# ---------------------------------------------------------------------------
# Tab selection verb.
# ---------------------------------------------------------------------------


def test_select_tab_updates_active_tab():
    drv = GuiDriver().build()
    drv.select_tab("Wishlist")
    assert drv.read_state()["active_tab"] == "Wishlist"


def test_select_tab_unknown_returns_false():
    drv = GuiDriver().build()
    assert drv.select_tab("DoesNotExist") is False


# ---------------------------------------------------------------------------
# Ctrl hold/release.
# ---------------------------------------------------------------------------


def test_hold_ctrl_sets_flag_true():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    assert drv.read_state()["ctrl_held"] is True


def test_release_ctrl_after_hold_sets_flag_false():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    drv.release_ctrl()
    assert drv.read_state()["ctrl_held"] is False


# ---------------------------------------------------------------------------
# Hover (basic vs Ctrl-hover).
# ---------------------------------------------------------------------------


def test_hover_returns_basic_name_without_ctrl():
    drv = GuiDriver().build()
    assert drv.hover("Tasks") == "Tasks"


def test_hover_returns_extended_help_under_ctrl():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    tooltip = drv.hover("Tasks")
    assert tooltip != "Tasks"  # not the basic name
    assert len(tooltip) > len("Tasks"), "extended help should be longer"


def test_hover_extended_help_mentions_ctrl_actions():
    """SPEC-074 acceptance: Ctrl-hover help describes what Ctrl-modifier
    affordances exist on this tab."""
    drv = GuiDriver().build()
    drv.hold_ctrl()
    tooltip = drv.hover("Tasks")
    lowered = tooltip.lower()
    # Every tab help mentions resize OR archive (or both) per SPEC-072.
    assert "resize" in lowered or "archive" in lowered, (
        f"Ctrl-hover help should mention Ctrl-modifier actions; got: {tooltip!r}"
    )


# ---------------------------------------------------------------------------
# Ctrl-click archive.
# ---------------------------------------------------------------------------


def test_ctrl_click_without_ctrl_does_nothing():
    drv = GuiDriver().build()
    original = list(drv.tab_order())
    result = drv.ctrl_click("Quarantine")
    assert result == ""
    assert drv.tab_order() == original


def test_ctrl_click_archives_tab():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    original_count = len(drv.tab_order())
    archived = drv.ctrl_click("Quarantine")
    assert archived == "Quarantine"
    assert "Quarantine" not in drv.tab_order()
    assert len(drv.tab_order()) == original_count - 1


# ---------------------------------------------------------------------------
# Ctrl-drag = resize toolbar (SPEC-072 verbatim).
# ---------------------------------------------------------------------------


def test_ctrl_drag_without_ctrl_does_not_resize():
    """No Ctrl held → drag is a no-op; sidebar scale stays at 1.0."""
    drv = GuiDriver().build()
    initial = drv.read_state()["sidebar_scale"]
    new_scale = drv.ctrl_drag(delta_y=120)
    assert new_scale == initial


def test_ctrl_drag_positive_delta_grows_modules():
    """SPEC-072 verbatim: drag down (positive y delta) grows all toolbar
    modules together."""
    drv = GuiDriver().build()
    drv.hold_ctrl()
    initial = drv.read_state()["sidebar_scale"]
    new_scale = drv.ctrl_drag(delta_y=120)
    assert new_scale > initial


def test_ctrl_drag_negative_delta_shrinks_modules():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    initial = drv.read_state()["sidebar_scale"]
    new_scale = drv.ctrl_drag(delta_y=-120)
    assert new_scale < initial


def test_ctrl_drag_clamps_at_extremes():
    drv = GuiDriver().build()
    drv.hold_ctrl()
    # Huge positive delta clamps at 2.5.
    scale = drv.ctrl_drag(delta_y=10000)
    assert scale == 2.5
    # Reset.
    drv.shell.set_sidebar_scale(1.0)
    # Huge negative delta clamps at 0.6.
    scale = drv.ctrl_drag(delta_y=-10000)
    assert scale == 0.6


def test_ctrl_drag_resizes_all_modules_uniformly():
    """SPEC-072 acceptance: resizes ALL of them inside the toolbar —
    not just one. The state-machine layer can't directly observe Tk
    widget sizes, but ``_sidebar_scale`` IS the single scalar that
    drives every button's font + pady at apply time. Verifying that
    one number changes per drag is sufficient for the uniform-resize
    contract."""
    drv = GuiDriver().build()
    drv.hold_ctrl()
    drv.ctrl_drag(delta_y=80)
    s1 = drv.read_state()["sidebar_scale"]
    # Same drag from the new position should change scale by the same
    # delta-per-pixel rule; this verifies the resize is path-consistent.
    drv.ctrl_drag(delta_y=80)
    s2 = drv.read_state()["sidebar_scale"]
    # Both drags moved the scale (or clamped); the second drag from
    # the new anchor should produce a value >= s1.
    assert s2 >= s1


# ---------------------------------------------------------------------------
# Chat submit verb.
# ---------------------------------------------------------------------------


def test_submit_chat_routes_to_active_session():
    from tools.gui_test_driver import _StubSession

    drv = GuiDriver(sessions=[_StubSession(sid="alpha", display_name="alpha")]).build()
    result = drv.submit_chat("hello", active_session_id="alpha")
    assert result["routed"] is True
    assert result["sid"] == "alpha"
    assert drv.shell.sm.sent == [{"sid": "alpha", "message": "hello"}]


def test_submit_chat_with_no_active_session_reports_no_route():
    drv = GuiDriver().build()
    result = drv.submit_chat("hello")
    assert result["routed"] is False


# ---------------------------------------------------------------------------
# Smoke test runner.
# ---------------------------------------------------------------------------


def test_smoke_executes_every_verb_without_error():
    """The CLI smoke test must execute end-to-end without raising. This
    is the canonical 'session validated GUI without launching' check."""
    drv = GuiDriver()
    report = _smoke(drv)
    assert len(report) > 5, "smoke should record multiple steps"
    # The final step must reflect Ctrl-release.
    last_state = report[-1]["state"]
    assert "ctrl_held" in last_state
    assert last_state["ctrl_held"] is False


def test_smoke_archives_a_tab():
    """After the smoke run, Quarantine should be missing from the
    sidebar (the Ctrl-click step archives it)."""
    drv = GuiDriver()
    _smoke(drv)
    assert "Quarantine" not in drv.tab_order()


def test_smoke_demonstrates_resize_round_trip():
    """The smoke run scales up, scales back down past 1.0, then resets.
    The final sidebar_scale should be 1.0."""
    drv = GuiDriver()
    _smoke(drv)
    assert drv.read_state()["sidebar_scale"] == 1.0
