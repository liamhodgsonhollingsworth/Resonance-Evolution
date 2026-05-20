"""
Tests for SPEC-068 chat-target routing via the workflow surface.

Covers ``route_chat`` (bare text / @-prefix / /all broadcast / empty),
``set_active_session`` (id / display_name / id-prefix resolution +
reactivation), the ``target`` action on Sessions view rows, and the
end-to-end paths from gui_test_driver through SessionManager stubs.
"""

from __future__ import annotations

import pytest

from tools.gui_test_driver import (
    GuiDriver,
    _StubInbox,
    _StubSession,
    _StubSessionManager,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_driver_with_sessions(*records: _StubSession) -> GuiDriver:
    """Build a driver pre-populated with stub sessions."""
    drv = GuiDriver(sessions=list(records))
    drv.build()
    return drv


# ---------------------------------------------------------------------------
# route_chat — empty + no active session.
# ---------------------------------------------------------------------------


def test_route_chat_empty_body_is_noop():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("")
    assert result["routed"] is False
    assert result["reason"] == "empty body"
    assert result["delivered_to"] == []


def test_route_chat_whitespace_only_is_noop():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("   \n  ")
    assert result["routed"] is False


def test_route_chat_no_active_session_bare_text():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    # No set_active_session call → active_session_id stays None.
    result = drv.route_chat("hello")
    assert result["routed"] is False
    assert "no active session" in result["reason"]


# ---------------------------------------------------------------------------
# route_chat — bare text to active session.
# ---------------------------------------------------------------------------


def test_route_chat_bare_text_to_active():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("ship it")
    assert result["routed"] is True
    assert result["target"] == "s-1"
    assert result["delivered_to"] == ["s-1"]
    assert result["message"] == "ship it"
    # Stub recorded the send.
    sent = drv.shell.sm.sent
    assert sent[-1] == {"sid": "s-1", "message": "ship it"}


# ---------------------------------------------------------------------------
# route_chat — @-prefix routing.
# ---------------------------------------------------------------------------


def test_route_chat_at_prefix_routes_to_named_session():
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker-1"),
        _StubSession("s-2", "worker-2"),
    )
    drv.set_active_session("s-1")
    result = drv.route_chat("@worker-2 status update?")
    assert result["routed"] is True
    assert result["target"] == "s-2"
    assert result["delivered_to"] == ["s-2"]
    # Active session unchanged — @-routing is one-shot.
    assert drv.active_session() == "s-1"


def test_route_chat_at_prefix_routes_to_id():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker-1"))
    drv.set_active_session("s-1")
    result = drv.route_chat("@s-1 hello via id")
    assert result["routed"] is True
    assert result["target"] == "s-1"


def test_route_chat_at_prefix_routes_to_id_prefix():
    """ID-prefix match (≥4 chars) so the maintainer doesn't have to
    type the full UUID."""
    drv = _make_driver_with_sessions(_StubSession("abc12345", "worker"))
    drv.set_active_session("abc12345")
    result = drv.route_chat("@abc1 prefix routing")
    assert result["routed"] is True
    assert result["target"] == "abc12345"


def test_route_chat_at_prefix_unknown_session():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("@nobody hello")
    assert result["routed"] is False
    assert "no session matched" in result["reason"]


def test_route_chat_at_prefix_missing_body():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("@worker")
    assert result["routed"] is False
    assert "@-prefix requires" in result["reason"]


def test_route_chat_at_prefix_empty_body():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    drv.set_active_session("s-1")
    result = drv.route_chat("@worker   ")
    assert result["routed"] is False


def test_route_chat_at_prefix_reactivates_archived():
    archived = _StubSession("s-arc", "archive-worker", status="archived")
    drv = _make_driver_with_sessions(archived)
    drv.set_active_session("s-arc")
    result = drv.route_chat("@archive-worker resume please")
    assert result["routed"] is True
    # Stub reactivate flipped the status.
    assert archived.status == "active"


# ---------------------------------------------------------------------------
# route_chat — /all broadcast.
# ---------------------------------------------------------------------------


def test_route_chat_broadcast_delivers_to_all():
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker-1"),
        _StubSession("s-2", "worker-2"),
        _StubSession("s-3", "worker-3"),
    )
    result = drv.route_chat("/all heads up")
    assert result["routed"] is True
    assert result["target"] == "all"
    assert set(result["delivered_to"]) == {"s-1", "s-2", "s-3"}


def test_route_chat_broadcast_skips_archived():
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker-1"),
        _StubSession("s-2", "worker-2", status="archived"),
        _StubSession("s-3", "worker-3"),
    )
    result = drv.route_chat("/all heads up")
    assert result["routed"] is True
    assert set(result["delivered_to"]) == {"s-1", "s-3"}
    assert "s-2" not in result["delivered_to"]


def test_route_chat_broadcast_empty_body():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    result = drv.route_chat("/all ")
    assert result["routed"] is False
    assert "empty" in result["reason"]


def test_route_chat_broadcast_with_no_sessions():
    drv = _make_driver_with_sessions()  # no sessions
    result = drv.route_chat("/all hello")
    assert result["routed"] is True  # broadcast intent satisfied
    assert result["delivered_to"] == []
    assert "0 session" in result["reason"]


# ---------------------------------------------------------------------------
# set_active_session.
# ---------------------------------------------------------------------------


def test_set_active_session_by_id():
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker"),
        _StubSession("s-2", "other"),
    )
    sid = drv.set_active_session("s-2")
    assert sid == "s-2"
    assert drv.active_session() == "s-2"


def test_set_active_session_by_display_name():
    drv = _make_driver_with_sessions(
        _StubSession("uuid-1", "my-worker"),
        _StubSession("uuid-2", "other"),
    )
    sid = drv.set_active_session("my-worker")
    assert sid == "uuid-1"


def test_set_active_session_by_id_prefix():
    drv = _make_driver_with_sessions(_StubSession("abc12345xyz", "worker"))
    sid = drv.set_active_session("abc1")
    assert sid == "abc12345xyz"


def test_set_active_session_unknown_returns_none():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    sid = drv.set_active_session("nonexistent")
    assert sid is None
    # Active session unchanged.
    assert drv.active_session() is None


def test_set_active_session_short_string_no_prefix_match():
    """A 3-char string is shorter than the prefix threshold so it
    must not match by prefix (only by exact id or display_name)."""
    drv = _make_driver_with_sessions(_StubSession("abcdef", "worker"))
    sid = drv.set_active_session("abc")
    assert sid is None


def test_set_active_session_reactivates_archived():
    archived = _StubSession("s-1", "worker", status="archived")
    drv = _make_driver_with_sessions(archived)
    sid = drv.set_active_session("s-1")
    assert sid == "s-1"
    # Reactivate flipped it.
    assert archived.status == "active"


def test_set_active_session_no_reactivate_when_active():
    """An already-active session must NOT be reactivated (no side
    effects on healthy sessions)."""
    active = _StubSession("s-1", "worker", status="active")
    drv = _make_driver_with_sessions(active)
    drv.set_active_session("s-1")
    assert active.status == "active"  # unchanged


# ---------------------------------------------------------------------------
# target action on Sessions view.
# ---------------------------------------------------------------------------


def test_sessions_view_items_carry_target_action(tmp_path):
    """SPEC-068 acceptance: clicking a row in Sessions makes it the
    active target. Sessions view items must declare the action."""
    from tools.active_sessions import register_session

    register_session("s-1", "apeiron", "implementation",
                     focus="testing", state_dir=tmp_path)
    drv = GuiDriver().build()
    drv.use_active_sessions_state_dir(tmp_path)
    items = drv.items_for_tab("Sessions")
    target_rows = [it for it in items if "target" in (it.get("actions") or [])]
    assert target_rows, "no row carries the 'target' action"


def test_chat_view_items_carry_target_action():
    """The Chat view (gui_chat kind, items_from_sessions) already
    surfaces target action so the Chat sidebar is clickable."""
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    items = drv.items_for_tab("Chat")
    assert any("target" in (it.get("actions") or []) for it in items)


def test_on_action_target_sets_active_session():
    drv = _make_driver_with_sessions(_StubSession("s-1", "worker"))
    # Simulate clicking the target action on a Sessions row.
    drv.shell._on_action("target", {"id": "s-1"})
    assert drv.active_session() == "s-1"


# ---------------------------------------------------------------------------
# Reversibility + ordering invariants.
# ---------------------------------------------------------------------------


def test_chat_routing_cycle_reversibility():
    """Switching active sessions 30 times leaves the state stable —
    no leaks, the most recent set_active_session wins."""
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker-1"),
        _StubSession("s-2", "worker-2"),
    )
    for _ in range(30):
        drv.set_active_session("s-1")
        drv.set_active_session("s-2")
    assert drv.active_session() == "s-2"


def test_at_prefix_does_not_change_active_session():
    """@-routing is one-shot; the active session must not change."""
    drv = _make_driver_with_sessions(
        _StubSession("s-1", "worker-1"),
        _StubSession("s-2", "worker-2"),
    )
    drv.set_active_session("s-1")
    drv.route_chat("@worker-2 one-shot message")
    drv.route_chat("@worker-2 another one-shot")
    drv.route_chat("@worker-2 and another")
    # Active still s-1 after three @-routed messages.
    assert drv.active_session() == "s-1"
