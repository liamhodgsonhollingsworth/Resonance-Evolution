"""
Tests for SPEC-074 standard-icons-by-default + hover-name + Ctrl-hover-help.

Layers:

- **Static maps** — ``SIDEBAR_VIEW_ICONS`` / ``ACTION_ICONS`` /
  ``BUTTON_EXTENDED_HELP`` are well-formed and consistent with the
  visual_contract icon registry.
- **GuiShell catalog** — every documented widget id has the right
  icon + tooltip + extended help assignment in the headless
  registry populated by ``__init__`` / ``register_default_widgets``.
- **Text-API verbs** — ``icon-for`` / ``tooltip-for`` /
  ``extended-help-for`` return the right values dispatched through
  ``tools.text_test.dispatch_command``.
- **Soft-fail** — when an icon name doesn't render, the widget
  falls back to its text label and the failure is surfaced via
  ``shell.icon_failures()``.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np
import pytest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from tools.workflow_gui.gui_shell import (
    ACTION_ICONS,
    BUTTON_EXTENDED_HELP,
    GuiShell,
    SIDEBAR_VIEW_ICONS,
)
from tools.visual_contract import list_icon_names


# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------


class _StubEngine:
    def __init__(self) -> None:
        self.cache: Dict[str, Any] = {}
        self.errors: List[str] = []

    def precompute(self) -> None:
        pass


class _StubInbox:
    def list_main(self, unread_only: bool = False):
        return []


class _StubSession:
    def __init__(self, sid: str, name: str, kind: str = "workflow-management") -> None:
        self.id = sid
        self.display_name = name
        self.session_type = kind
        self.status = "active"


class _StubSessionManager:
    state_dir = Path(".")

    def list(self):
        return []

    def get(self, _sid):
        return None

    def send(self, _sid, _msg):
        pass

    def spawn(self, **_kw):
        return _StubSession("stub", "stub")

    def shutdown(self):
        pass


def _make_shell() -> GuiShell:
    return GuiShell(
        engine=_StubEngine(),
        session_manager=_StubSessionManager(),
        inbox=_StubInbox(),
        root=Path("."),
        scene_path=None,
        scene_root_id=None,
    )


# ---------------------------------------------------------------------------
# Static maps — well-formedness
# ---------------------------------------------------------------------------


def test_every_sidebar_icon_name_is_registered_in_visual_contract():
    """If we point at an icon that doesn't exist in visual_contract,
    the button silently degrades. Tests catch this at static-map
    edit time."""
    available = set(list_icon_names())
    for view_name, icon_name in SIDEBAR_VIEW_ICONS.items():
        assert icon_name in available, (
            f"SIDEBAR_VIEW_ICONS maps {view_name!r} to {icon_name!r} "
            f"which is not in visual_contract"
        )


def test_every_action_icon_name_is_registered_in_visual_contract():
    available = set(list_icon_names())
    for action, icon_name in ACTION_ICONS.items():
        assert icon_name in available, (
            f"ACTION_ICONS maps {action!r} to {icon_name!r} "
            f"which is not in visual_contract"
        )


def test_sidebar_icons_cover_the_named_views_from_spec():
    """SPEC-074 verbatim mentions inbox, history/archive, settings,
    search, etc. The minimum set we ship: every default view in
    the registry has an icon row."""
    required = {
        "Tasks", "Ideas", "Wishlist",
        "Inbox", "Chat", "Quarantine", "Trusted Senders",
        "3D", "Logs", "Sessions", "Archive",
    }
    missing = required - set(SIDEBAR_VIEW_ICONS)
    assert not missing, f"sidebar icons missing for: {sorted(missing)}"


def test_action_icons_cover_archive_lock_unlock_copy_paste():
    """The maintainer's spec calls out archive + lock + copy/paste
    specifically. Coverage assertion catches a regression at static-
    map edit time."""
    required = {"archive", "lock", "unlock", "copy", "paste", "expand"}
    missing = required - set(ACTION_ICONS)
    assert not missing, f"action icons missing for: {sorted(missing)}"


def test_button_extended_help_covers_every_action_icon_key():
    """Every action that maps to a standard icon should also carry
    Ctrl-hover extended help. Otherwise the Ctrl-hover branch falls
    back to the basic name silently."""
    missing = set(ACTION_ICONS) - set(BUTTON_EXTENDED_HELP)
    assert not missing, (
        f"actions without extended help (Ctrl-hover would fall back "
        f"to basic): {sorted(missing)}"
    )


def test_button_extended_help_covers_send_go_refresh():
    """Free-standing chrome buttons need extended help too."""
    for name in ("Send", "Go", "Refresh"):
        assert name in BUTTON_EXTENDED_HELP, (
            f"BUTTON_EXTENDED_HELP missing entry for {name!r}"
        )


# ---------------------------------------------------------------------------
# GuiShell registry
# ---------------------------------------------------------------------------


def test_shell_registers_sidebar_view_icons_on_construction():
    shell = _make_shell()
    assert shell.icon_for("sidebar:Tasks") == "check-square"
    assert shell.icon_for("sidebar:Ideas") == "lightbulb"
    assert shell.icon_for("sidebar:Wishlist") == "star"
    assert shell.icon_for("sidebar:Inbox") == "inbox"
    assert shell.icon_for("sidebar:Chat") == "message-circle"
    assert shell.icon_for("sidebar:Quarantine") == "shield-alert"
    assert shell.icon_for("sidebar:Trusted Senders") == "shield-check"
    assert shell.icon_for("sidebar:3D") == "box"
    assert shell.icon_for("sidebar:Logs") == "file-text"
    assert shell.icon_for("sidebar:Sessions") == "users"
    assert shell.icon_for("sidebar:Archive") == "archive"


def test_shell_registers_sidebar_tooltips_on_construction():
    """Each sidebar view's basic tooltip is its name; the extended
    tooltip is its registry ``description``."""
    shell = _make_shell()
    assert shell.tooltip_for("sidebar:Tasks") == "Tasks"
    assert shell.tooltip_for("sidebar:Inbox") == "Inbox"
    extended = shell.extended_help_for("sidebar:Tasks")
    assert "FileSource" in extended or "Tasks panel" in extended


def test_shell_registers_action_prototype_icons():
    shell = _make_shell()
    assert shell.icon_for("action:proto:archive") == "archive"
    assert shell.icon_for("action:proto:lock") == "lock"
    assert shell.icon_for("action:proto:unlock") == "unlock"
    assert shell.icon_for("action:proto:copy") == "copy"
    assert shell.icon_for("action:proto:paste") == "clipboard"
    assert shell.icon_for("action:proto:expand") == "chevron-down"


def test_shell_registers_action_prototype_tooltips_and_extended_help():
    shell = _make_shell()
    assert shell.tooltip_for("action:proto:archive") == "Archive"
    assert "Archive" in shell.extended_help_for("action:proto:archive")
    assert "Lock" in shell.extended_help_for("action:proto:lock")


def test_shell_registers_chat_send_tooltip():
    shell = _make_shell()
    assert shell.tooltip_for("chat:Send") == "Send"
    assert "chat" in shell.extended_help_for("chat:Send").lower()


def test_shell_registers_browser_go_icon_and_tooltip():
    shell = _make_shell()
    assert shell.icon_for("browser:Go") == "chevron-right"
    assert shell.tooltip_for("browser:Go") == "Go"
    assert "URL" in shell.extended_help_for("browser:Go")


def test_shell_registers_browser_refresh_tooltip_no_icon():
    """Refresh stays text-only (no Lucide refresh glyph in the
    bundled subset)."""
    shell = _make_shell()
    assert shell.icon_for("browser:Refresh") == ""  # soft-fall
    assert shell.tooltip_for("browser:Refresh") == "Refresh"


def test_icon_for_returns_empty_string_for_unknown_widget():
    """Unknown widget id should soft-fall to empty string, not raise."""
    shell = _make_shell()
    assert shell.icon_for("nonexistent:Widget") == ""


def test_tooltip_for_returns_empty_string_for_unknown_widget():
    shell = _make_shell()
    assert shell.tooltip_for("nonexistent:Widget") == ""


def test_extended_help_for_returns_empty_string_for_unknown_widget():
    shell = _make_shell()
    assert shell.extended_help_for("nonexistent:Widget") == ""


def test_list_registered_widgets_returns_sorted_unique_names():
    shell = _make_shell()
    names = shell.list_registered_widgets()
    # Sorted determinism.
    assert names == sorted(names)
    # No duplicates.
    assert len(names) == len(set(names))
    # At least the sidebar+action+chrome buttons.
    assert "sidebar:Tasks" in names
    assert "action:proto:archive" in names
    assert "chat:Send" in names


def test_register_default_widgets_is_idempotent():
    shell = _make_shell()
    # Run twice; counts should stay identical.
    before = shell.list_registered_widgets()
    shell.register_default_widgets()
    after = shell.list_registered_widgets()
    assert before == after


def test_register_widget_icon_records_assignment():
    shell = _make_shell()
    shell.register_widget_icon("custom:WidgetX", "lock")
    assert shell.icon_for("custom:WidgetX") == "lock"


def test_register_widget_tooltip_records_basic_and_extended():
    shell = _make_shell()
    shell.register_widget_tooltip(
        "custom:WidgetY",
        basic_text="Y",
        extended_text="Y - extended.",
    )
    assert shell.tooltip_for("custom:WidgetY") == "Y"
    assert shell.extended_help_for("custom:WidgetY") == "Y - extended."


def test_register_widget_tooltip_with_empty_extended_only_records_basic():
    shell = _make_shell()
    shell.register_widget_tooltip(
        "custom:WidgetZ",
        basic_text="Z",
        extended_text="",
    )
    assert shell.tooltip_for("custom:WidgetZ") == "Z"
    # Empty extended is treated as "no Ctrl-hover help registered".
    assert shell.extended_help_for("custom:WidgetZ") == ""


# ---------------------------------------------------------------------------
# Soft-fail behavior
# ---------------------------------------------------------------------------


def test_resolve_icon_image_returns_none_for_unknown_name():
    """Unknown icon name must soft-fail; the button falls back to text."""
    shell = _make_shell()
    photo = shell._resolve_icon_image("definitely-not-a-real-icon")
    assert photo is None
    # The failure is recorded so the ready-check probe can surface it.
    failures = shell.icon_failures()
    assert any("definitely-not-a-real-icon" in f for f in failures)


def test_resolve_icon_image_returns_none_for_empty_name():
    """Empty icon name is the soft-fall case; no failure recorded."""
    shell = _make_shell()
    assert shell._resolve_icon_image("") is None
    assert all(
        "(empty)" not in f for f in shell.icon_failures()
    )  # No bogus failure recorded.


def test_icon_failures_starts_empty():
    shell = _make_shell()
    assert shell.icon_failures() == []


# ---------------------------------------------------------------------------
# Text-API verb dispatch
# ---------------------------------------------------------------------------


@pytest.fixture
def engine_with_shell():
    """Build a real Engine with the GuiShell attached so the text-API
    verbs can find it via ``engine.gui_shell``."""
    from engine import Engine, View, look_at
    e = Engine(root_dir=ROOT)
    e.discover()
    shell = _make_shell()
    setattr(e, "gui_shell", shell)
    v = View(
        position=np.asarray([3.0, 2.0, 5.0]),
        orientation=look_at(
            np.asarray([3.0, 2.0, 5.0]), np.asarray([0.0, 0.0, 0.0])
        ),
        width=64, height=64, scale=1.0,
    )
    return e, v


def test_icon_for_verb_returns_assigned_icon(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "icon-for sidebar:Tasks", v)
    assert result.startswith("OK:")
    assert "check-square" in result


def test_icon_for_verb_reports_no_icon_for_soft_fall(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "icon-for browser:Refresh", v)
    assert result.startswith("OK:")
    assert "(no icon)" in result


def test_icon_for_verb_errors_on_unknown_widget_id_silently_returns_no_icon(engine_with_shell):
    """Unknown widget id is the soft-fall case for ``icon-for``;
    returns OK + (no icon) rather than ERR."""
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "icon-for totally-unknown:Widget", v)
    assert result.startswith("OK:")
    assert "(no icon)" in result


def test_icon_for_verb_errors_with_no_args(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "icon-for", v)
    assert result.startswith("ERR:")
    assert "<widget-id>" in result


def test_tooltip_for_verb_returns_basic_tooltip(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "tooltip-for sidebar:Inbox", v)
    assert result.startswith("OK:")
    assert "Inbox" in result


def test_extended_help_for_verb_returns_ctrl_hover_text(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    result, _ = dispatch_command(e, "extended-help-for sidebar:Tasks", v)
    assert result.startswith("OK:")
    # The default registry's Tasks description mentions FileSource.
    assert "FileSource" in result or "tasks.md" in result


def test_extended_help_for_verb_no_help_returns_marker(engine_with_shell):
    from tools.text_test import dispatch_command
    e, v = engine_with_shell
    # An unknown id has no help → soft-fall to the (no extended help)
    # marker.
    result, _ = dispatch_command(e, "extended-help-for nonexistent:Widget", v)
    assert result.startswith("OK:")
    assert "(no extended help)" in result


def test_verbs_error_when_no_gui_shell_attached():
    """Engine without a gui_shell → the verbs return ERR with a
    clear pointer."""
    from engine import Engine, View, look_at
    from tools.text_test import dispatch_command
    e = Engine(root_dir=ROOT)
    e.discover()
    v = View(
        position=np.asarray([3.0, 2.0, 5.0]),
        orientation=look_at(
            np.asarray([3.0, 2.0, 5.0]), np.asarray([0.0, 0.0, 0.0])
        ),
        width=64, height=64, scale=1.0,
    )
    for verb in ("icon-for", "tooltip-for", "extended-help-for"):
        result, _ = dispatch_command(e, f"{verb} sidebar:Tasks", v)
        assert result.startswith("ERR:")
        assert "gui_shell" in result.lower()
