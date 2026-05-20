"""
Regression tests for stress-test-surfaced bugs in the post-compact arc.

These tests lock in the fixes shipped 2026-05-20 for issues the
SPEC-067 / SPEC-079 / SPEC-068 / SPEC-073 test suites missed. Each
test names the bug + the stress-test report finding it derives from.

Stress-test report at notes/stress_tests/post_compact_arc_2026_05_20.md.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

import pytest

from tools.active_sessions import (
    list_active_sessions,
    register_session,
    registry_path,
    unregister_session,
)
from tools.gui_test_driver import GuiDriver, _StubSession
from tools.module_clipboard import instantiate_module


# ---------------------------------------------------------------------------
# Module clipboard — duplicate-id-in-snippet (stress-test BUG #1).
# ---------------------------------------------------------------------------


def test_instantiate_duplicate_id_in_snippet_against_empty_engine():
    """Stress-test finding: a snippet with [{'id': 'X'}, {'id': 'X'}]
    used to silently produce new_ids=['X', 'X_2'] but BOTH spawn into
    the same engine slot. After fix, each snippet index gets its own
    resolved id and both new nodes survive."""

    class _StubEngine:
        def __init__(self):
            self.nodes = {}

        def spawn(self, node_id, type_name, params, connections):
            # Minimal node-instance stub.
            from engine.node import NodeInstance
            self.nodes[node_id] = NodeInstance(
                id=node_id, type_name=type_name,
                params=params, connections=connections,
            )

    e = _StubEngine()
    module = [
        {"id": "X", "type": "T", "params": {"a": 1}, "connections": {}},
        {"id": "X", "type": "T", "params": {"a": 2}, "connections": {}},
    ]
    new_ids = instantiate_module(e, module)
    # Both ids must be distinct in the returned list.
    assert len(new_ids) == 2
    assert new_ids[0] != new_ids[1]
    assert new_ids[0] == "X"
    assert new_ids[1] == "X_2"
    # Both nodes must live in the engine.
    assert "X" in e.nodes
    assert "X_2" in e.nodes
    # Each got its own params.
    assert e.nodes["X"].params == {"a": 1}
    assert e.nodes["X_2"].params == {"a": 2}


def test_instantiate_duplicate_id_in_snippet_against_engine_with_existing():
    """Stress-test variant: snippet has duplicates AND the engine
    already has the original id. All three must produce distinct
    survivors."""

    class _StubEngine:
        def __init__(self):
            from engine.node import NodeInstance
            self.nodes = {
                "X": NodeInstance(id="X", type_name="T", params={"a": 0}, connections={}),
            }

        def spawn(self, node_id, type_name, params, connections):
            from engine.node import NodeInstance
            self.nodes[node_id] = NodeInstance(
                id=node_id, type_name=type_name,
                params=params, connections=connections,
            )

    e = _StubEngine()
    module = [
        {"id": "X", "type": "T", "params": {"a": 1}, "connections": {}},
        {"id": "X", "type": "T", "params": {"a": 2}, "connections": {}},
    ]
    new_ids = instantiate_module(e, module)
    assert len(new_ids) == 2
    assert len(set(new_ids)) == 2  # distinct
    assert new_ids[0] == "X_2"
    assert new_ids[1] == "X_3"
    assert "X" in e.nodes  # original survives
    assert "X_2" in e.nodes
    assert "X_3" in e.nodes


# ---------------------------------------------------------------------------
# active_sessions — concurrent writes (stress-test BUG #2).
# ---------------------------------------------------------------------------


def test_concurrent_registrations_do_not_lose_update(tmp_path):
    """Stress-test finding: 50 concurrent register_session calls
    produced only 2 surviving entries due to read-modify-write races.
    After lock fix, all 30 must survive (we use 30 here rather than
    50 to keep the test fast; the failure mode is the same)."""
    N = 30
    results: list = [None] * N
    errors: list = []

    def worker(idx):
        try:
            register_session(
                f"sess-{idx:03d}",
                project="p",
                session_type="t",
                focus=f"worker {idx}",
                state_dir=tmp_path,
            )
            results[idx] = True
        except Exception as exc:
            errors.append((idx, repr(exc)))
            results[idx] = False

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15.0)

    # All workers succeeded.
    assert not errors, f"register_session raised: {errors[:5]}"
    assert all(r is True for r in results)

    # All entries survive in the registry.
    sessions = list_active_sessions(state_dir=tmp_path, include_stale=True)
    surviving_ids = sorted(s.id for s in sessions)
    expected_ids = sorted(f"sess-{i:03d}" for i in range(N))
    assert surviving_ids == expected_ids, (
        f"lost-update: {len(surviving_ids)}/{N} survived; "
        f"missing {sorted(set(expected_ids) - set(surviving_ids))[:5]}"
    )


def test_concurrent_heartbeats_do_not_lose_update(tmp_path):
    """Heartbeats hit the same read-modify-write cycle as register.
    Pre-register 10 sessions, then concurrent heartbeat each to a
    fresh focus — every heartbeat must take effect."""
    for i in range(10):
        register_session(
            f"hb-{i}", project="p", session_type="t",
            state_dir=tmp_path,
        )

    from tools.active_sessions import heartbeat

    def worker(i):
        heartbeat(f"hb-{i}", focus=f"updated-{i}", state_dir=tmp_path)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10.0)

    sessions = {s.id: s for s in list_active_sessions(state_dir=tmp_path, include_stale=True)}
    for i in range(10):
        assert sessions[f"hb-{i}"].focus == f"updated-{i}"


# ---------------------------------------------------------------------------
# active_sessions — empty/None id validation (stress-test BUG).
# ---------------------------------------------------------------------------


def test_register_session_rejects_empty_string_id(tmp_path):
    with pytest.raises(ValueError):
        register_session("", "p", "t", state_dir=tmp_path)


def test_register_session_rejects_none_id(tmp_path):
    with pytest.raises(ValueError):
        register_session(None, "p", "t", state_dir=tmp_path)  # type: ignore[arg-type]


def test_heartbeat_empty_id_returns_false_not_match(tmp_path):
    """Heartbeat with empty id must not match any orphan entry."""
    register_session("real", "p", "t", state_dir=tmp_path)
    from tools.active_sessions import heartbeat
    assert heartbeat("", state_dir=tmp_path) is False
    assert heartbeat(None, state_dir=tmp_path) is False  # type: ignore[arg-type]


def test_unregister_empty_id_returns_false(tmp_path):
    register_session("real", "p", "t", state_dir=tmp_path)
    assert unregister_session("", state_dir=tmp_path) is False
    assert unregister_session(None, state_dir=tmp_path) is False  # type: ignore[arg-type]
    # Real session untouched.
    assert any(s.id == "real" for s in list_active_sessions(state_dir=tmp_path))


# ---------------------------------------------------------------------------
# active_sessions — orphan tmp file on TypeError (stress-test BUG).
# ---------------------------------------------------------------------------


def test_non_serializable_metadata_does_not_leave_orphan(tmp_path):
    """A non-JSON-serializable metadata value (e.g. a lambda) used to
    raise TypeError after creating a .tmp file, leaving the orphan
    behind. After fix, the tmp is cleaned up + the raise propagates."""
    with pytest.raises(TypeError):
        register_session(
            "bad",
            project="p",
            session_type="t",
            metadata={"callback": lambda x: x},
            state_dir=tmp_path,
        )
    # No orphan .tmp files remain.
    tmp_files = list(tmp_path.glob("*.tmp.*"))
    assert tmp_files == [], f"orphan tmp files: {tmp_files}"


# ---------------------------------------------------------------------------
# gui_shell — archive-all leaves active_tab dangling (stress-test BUG).
# ---------------------------------------------------------------------------


def test_archive_all_views_clears_active_tab():
    """Stress-test finding: archiving every view used to leave
    active_tab pointing at a now-archived view because the fallback
    was DEFAULT_TAB even when Tasks was also archived. After fix,
    active_tab is None when no visible view remains."""
    drv = GuiDriver().build()
    drv.set_view("Tasks")
    # Archive every view.
    for name in list(drv.list_views()):
        drv.hold_ctrl()
        drv.ctrl_click(name)
    # No visible views, no dangling active_tab.
    assert drv.list_views() == []
    assert drv.current_view() is None


def test_archive_all_except_default_keeps_default_active():
    """When DEFAULT_TAB ("Tasks") is still visible after an archive,
    the fallback prefers it even if the archived tab wasn't Tasks."""
    drv = GuiDriver().build()
    drv.set_view("Inbox")
    drv.hold_ctrl()
    drv.ctrl_click("Inbox")
    # Fallback should be Tasks (DEFAULT_TAB), not the first-listed.
    assert drv.current_view() == "Tasks"


# ---------------------------------------------------------------------------
# gui_shell — id-prefix ambiguity (stress-test BUG).
# ---------------------------------------------------------------------------


def test_id_prefix_ambiguity_returns_none():
    """Two sessions sharing a 4-char prefix used to silently route to
    the first-listed. After fix, ambiguous prefix returns None."""
    drv = GuiDriver(sessions=[
        _StubSession("abcd1234", "worker-1"),
        _StubSession("abcd5678", "worker-2"),
    ]).build()
    sid = drv.set_active_session("abcd")
    assert sid is None
    # No active session set.
    assert drv.active_session() is None


def test_id_prefix_unique_match_still_works():
    """The ambiguity check must not break the unique-prefix case."""
    drv = GuiDriver(sessions=[
        _StubSession("abcd1234", "worker-1"),
        _StubSession("xyz98765", "worker-2"),
    ]).build()
    sid = drv.set_active_session("abcd")
    assert sid == "abcd1234"


def test_at_prefix_route_with_ambiguous_id_returns_err():
    drv = GuiDriver(sessions=[
        _StubSession("abcd1111", "worker-1"),
        _StubSession("abcd2222", "worker-2"),
    ]).build()
    drv.set_active_session("abcd1111")
    result = drv.route_chat("@abcd hello")
    assert result["routed"] is False
    assert "no session matched" in result["reason"]
