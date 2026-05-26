"""Deferred-concerns #17 consolidation tests for chat_router_core.

These tests cover the consolidation invariants the three formerly-
divergent routing implementations should now share via
``tools.workflow.chat_router_core``:

  - Identical routing decisions for identical inputs across the three
    callers (Tk gui_shell.route_chat, terminal/Streamlit
    chat_router-node, website _route_natural_language).
  - The race-window scenarios from deferred-concerns #13 + #14
    (concurrent calls don't orphan-spawn or lose active-session
    state).
  - The failure-surfacing parity from deferred-concerns #16 (the
    surface_failure hook fires for every soft-fail, regardless of
    which caller invoked route_chat).
  - The legacy text shape for routing-decision dicts is preserved
    (consumers downstream parse ``routed``, ``target``,
    ``delivered_to``, ``message``, ``reason``).

Tests use stub SessionManager + Inbox shims rather than real
SessionManager instances so they run fast (~0.5s total).
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from tools.workflow import chat_router_core


# ---------------------------------------------------------------------
# Stubs.
# ---------------------------------------------------------------------


class _StubRec:
    def __init__(
        self,
        sid: str,
        display_name: str = "",
        session_type: str = "general",
        status: str = "active",
        last_active_at: str = "",
    ) -> None:
        self.id = sid
        self.display_name = display_name or sid
        self.session_type = session_type
        self.status = status
        self.last_active_at = last_active_at


class _StubSM:
    def __init__(self, recs: Optional[List[_StubRec]] = None) -> None:
        self._recs = recs or []
        self.sent: List[Tuple[str, str]] = []
        self.spawn_calls: List[Dict[str, Any]] = []
        self.reactivated: List[str] = []
        self.fail_send_with: Optional[Exception] = None
        self.state_dir: Optional[Path] = None

    def get(self, sid: str) -> Optional[_StubRec]:
        for rec in self._recs:
            if rec.id == sid:
                return rec
        return None

    def list(self) -> List[_StubRec]:
        return list(self._recs)

    def send(self, sid: str, body: str) -> None:
        if self.fail_send_with is not None:
            raise self.fail_send_with
        self.sent.append((sid, body))

    def reactivate(self, sid: str) -> None:
        self.reactivated.append(sid)
        for rec in self._recs:
            if rec.id == sid and rec.status == "archived":
                rec.status = "active"

    def spawn(self, **kwargs: Any) -> _StubRec:
        self.spawn_calls.append(dict(kwargs))
        sid = f"spawned-{len(self.spawn_calls)}"
        rec = _StubRec(sid, display_name=kwargs.get("display_name", ""))
        self._recs.append(rec)
        return rec


class _StubInbox:
    def __init__(self) -> None:
        self.posts: List[Dict[str, Any]] = []
        self.fail_with: Optional[Exception] = None

    def post(self, **kwargs: Any) -> Path:
        if self.fail_with is not None:
            raise self.fail_with
        self.posts.append(kwargs)
        return Path("/fake/post")


# ---------------------------------------------------------------------
# Behavioral-parity tests across the three surfaces' inputs.
# ---------------------------------------------------------------------


def test_bare_text_routes_to_active_session() -> None:
    """The Tk surface's typical input shape: explicit active session id."""
    sm = _StubSM([_StubRec("sess-1")])
    result = chat_router_core.route_chat(
        "hello there",
        session_manager=sm,
        active_session_id="sess-1",
    )
    assert result["routed"] is True
    assert result["target"] == "sess-1"
    assert result["delivered_to"] == ["sess-1"]
    assert sm.sent == [("sess-1", "hello there")]


def test_bare_text_falls_back_to_default_picker() -> None:
    """The website surface's typical shape: no active id, picker
    selects from the SessionManager registry."""
    sm = _StubSM([
        _StubRec("wf-mgmt-sess", session_type="workflow_management"),
        _StubRec("dev-sess", session_type="parallel-development"),
    ])

    def _picker(sessions: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        for s in sessions:
            if s.get("session_type") == "workflow_management":
                return s
        return None

    result = chat_router_core.route_chat(
        "build a button",
        session_manager=sm,
        default_target_picker=_picker,
    )
    assert result["routed"] is True
    assert result["target"] == "wf-mgmt-sess"
    assert sm.sent == [("wf-mgmt-sess", "build a button")]


def test_bare_text_auto_spawns_when_no_target() -> None:
    """The website surface's bootstrap: no active id, no picker hit,
    auto-spawn fires with the maintainer's text as seed."""
    sm = _StubSM([])
    spawn_log: List[str] = []

    def _spawner(text: str) -> Dict[str, Any]:
        spawn_log.append(text)
        return {"ok": True, "session_id": "fresh-spawned-aaaa"}

    result = chat_router_core.route_chat(
        "first message",
        session_manager=sm,
        default_target_picker=lambda _ss: None,
        auto_spawn_handler=_spawner,
    )
    assert result["routed"] is True
    assert result["target"] == "fresh-spawned-aaaa"
    assert "auto-spawned" in result["reason"]
    assert spawn_log == ["first message"]


def test_bare_text_no_target_no_spawner_soft_fails() -> None:
    """The Tk surface's empty-state: no active id, no picker, no
    auto-spawn. The result is a soft-fail with a clear reason."""
    sm = _StubSM([])
    result = chat_router_core.route_chat(
        "hello",
        session_manager=sm,
    )
    assert result["routed"] is False
    assert "no active session" in result["reason"]


def test_at_prefix_routes_to_named_session() -> None:
    sm = _StubSM([_StubRec("aaaa1111-bbbb", display_name="worker")])
    result = chat_router_core.route_chat(
        "@worker do the thing",
        session_manager=sm,
    )
    assert result["routed"] is True
    assert result["target"] == "aaaa1111-bbbb"
    assert sm.sent == [("aaaa1111-bbbb", "do the thing")]


def test_slash_all_broadcasts_to_active_sessions() -> None:
    sm = _StubSM([
        _StubRec("a"),
        _StubRec("b"),
        _StubRec("c", status="archived"),
    ])
    result = chat_router_core.route_chat(
        "/all heads up",
        session_manager=sm,
    )
    assert result["routed"] is True
    assert result["target"] == "all"
    assert set(result["delivered_to"]) == {"a", "b"}
    assert ("c", "heads up") not in sm.sent


def test_empty_body_is_noop() -> None:
    sm = _StubSM([])
    result = chat_router_core.route_chat(
        "  ",
        session_manager=sm,
    )
    assert result["routed"] is False
    assert result["reason"] == "empty body"


# ---------------------------------------------------------------------
# Lock-protection tests (deferred-concerns #13 + #14).
# ---------------------------------------------------------------------


def test_route_chat_holds_lock_during_target_resolution() -> None:
    """The active-session resolution + (when applicable) auto-spawn
    fallback happen inside the lock so concurrent callers' reads of
    ``active_session_id`` and writes to the marker file cannot
    interleave (closes deferred-concerns #13 + #14). The actual
    ``sm.send`` call happens outside the lock by design — the network
    delivery does not touch the resolver state, so serializing it
    would add latency without closing any race.

    Verified by spying on the picker (which is INSIDE the lock) and
    asserting it only sees one caller at a time, then confirming the
    sends fire serially-or-concurrently (we don't care which).
    """
    sm = _StubSM([_StubRec("sess-1", session_type="workflow_management")])
    lock = threading.Lock()
    in_critical = {"max": 0, "current": 0}
    lock_inspect = threading.Lock()

    def _picker(sessions: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        # Spy: count concurrent invocations. If the lock is held,
        # only one picker call can be in flight at a time.
        with lock_inspect:
            in_critical["current"] += 1
            in_critical["max"] = max(
                in_critical["max"], in_critical["current"]
            )
        import time
        time.sleep(0.05)
        with lock_inspect:
            in_critical["current"] -= 1
        return sessions[0] if sessions else None

    threads = [
        threading.Thread(
            target=lambda: chat_router_core.route_chat(
                "msg", session_manager=sm,
                default_target_picker=_picker, lock=lock,
            )
        )
        for _ in range(5)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert in_critical["max"] == 1, (
        f"lock failed: up to {in_critical['max']} pickers ran "
        f"concurrently; expected serialized to 1"
    )
    assert len(sm.sent) == 5


def test_ensure_default_session_serializes_concurrent_callers(
    tmp_path: Path,
) -> None:
    """Two threads call ensure_default_workflow_mgmt_session at the
    same time; only one spawn should fire because the lock serializes
    the marker-check + spawn critical section.
    """
    sm = _StubSM([])
    sm.state_dir = tmp_path
    lock = threading.Lock()

    sids: List[Optional[str]] = []
    barrier = threading.Barrier(2)

    def _runner() -> None:
        barrier.wait()  # release both at once
        sid = chat_router_core.ensure_default_workflow_mgmt_session(
            session_manager=sm,
            seed_builder=lambda: "seed",
            cwd=tmp_path,
            lock=lock,
        )
        sids.append(sid)

    t1 = threading.Thread(target=_runner)
    t2 = threading.Thread(target=_runner)
    t1.start(); t2.start()
    t1.join(); t2.join()

    assert len(sm.spawn_calls) == 1, (
        f"concurrent boot orphan-spawned: got {len(sm.spawn_calls)} "
        "spawns; expected 1"
    )
    assert sids[0] == sids[1], (
        f"sids diverged: {sids!r}; both threads should return the "
        "same canonical session id"
    )


def test_ensure_default_session_respawns_when_archived(
    tmp_path: Path,
) -> None:
    """Marker exists but the recorded session is archived → fresh
    spawn fires (parity with the legacy implementation)."""
    archived = _StubRec("old-sid", status="archived")
    sm = _StubSM([archived])
    sm.state_dir = tmp_path
    marker = tmp_path / "default_workflow_mgmt.txt"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("old-sid", encoding="utf-8")

    sid = chat_router_core.ensure_default_workflow_mgmt_session(
        session_manager=sm,
        seed_builder=lambda: "fresh seed",
        cwd=tmp_path,
    )
    assert sid is not None
    assert sid != "old-sid", "archived session should not be reused"
    assert len(sm.spawn_calls) == 1


# ---------------------------------------------------------------------
# Failure-surfacing tests (deferred-concerns #16).
# ---------------------------------------------------------------------


def test_surface_failure_fires_on_no_active_session() -> None:
    """When the bare-body path has no target, surface_failure receives
    the reason text — the GUI shell can then write back into the chat
    input, the terminal shell can print, the website can fold it
    into the response payload. Parity is the consolidation invariant.
    """
    sm = _StubSM([])
    surfaced: List[Tuple[str, Optional[str]]] = []

    def _surface(reason: str, hint: Optional[str]) -> None:
        surfaced.append((reason, hint))

    chat_router_core.route_chat(
        "no target",
        session_manager=sm,
        surface_failure=_surface,
    )
    assert len(surfaced) == 1
    assert "no active session" in surfaced[0][0]


def test_surface_failure_fires_on_send_error() -> None:
    sm = _StubSM([_StubRec("sess-1")])
    sm.fail_send_with = RuntimeError("pipe broken")
    surfaced: List[Tuple[str, Optional[str]]] = []
    chat_router_core.route_chat(
        "doomed",
        session_manager=sm,
        active_session_id="sess-1",
        surface_failure=lambda r, h: surfaced.append((r, h)),
    )
    assert len(surfaced) == 1
    assert "pipe broken" in surfaced[0][0]


def test_surface_failure_does_not_fire_on_success() -> None:
    sm = _StubSM([_StubRec("sess-1")])
    surfaced: List[Tuple[str, Optional[str]]] = []
    chat_router_core.route_chat(
        "happy path",
        session_manager=sm,
        active_session_id="sess-1",
        surface_failure=lambda r, h: surfaced.append((r, h)),
    )
    assert surfaced == []


def test_ensure_default_session_surface_failure_on_spawn_error(
    tmp_path: Path,
) -> None:
    """If spawn raises, surface_failure receives the error text +
    a hint. Closes #16's GUI-silent-on-failure gap."""

    class _FailingSM(_StubSM):
        def spawn(self, **kwargs: Any) -> _StubRec:
            raise RuntimeError("claude binary missing")

    sm = _FailingSM([])
    sm.state_dir = tmp_path
    surfaced: List[Tuple[str, Optional[str]]] = []
    sid = chat_router_core.ensure_default_workflow_mgmt_session(
        session_manager=sm,
        seed_builder=lambda: "seed",
        cwd=tmp_path,
        surface_failure=lambda r, h: surfaced.append((r, h)),
    )
    assert sid is None
    assert len(surfaced) == 1
    assert "claude binary missing" in surfaced[0][0]
    # Hint preserves the terminal-shell's helpful suggestion shape.
    assert surfaced[0][1] is not None
    assert "spawn manually" in surfaced[0][1]


# ---------------------------------------------------------------------
# Audit-log tests (deferred-concerns #15 — partial inline).
# ---------------------------------------------------------------------


def test_audit_log_fires_on_routed_success() -> None:
    sm = _StubSM([_StubRec("sess-1")])
    log: List[Dict[str, Any]] = []
    chat_router_core.route_chat(
        "audit me",
        session_manager=sm,
        active_session_id="sess-1",
        audit_log=lambda e: log.append(e),
    )
    assert len(log) == 1
    assert log[0]["routed"] is True
    assert log[0]["target"] == "sess-1"
    assert log[0]["actor"] == "maintainer"


def test_audit_log_fires_on_soft_fail() -> None:
    sm = _StubSM([])
    log: List[Dict[str, Any]] = []
    chat_router_core.route_chat(
        "no target",
        session_manager=sm,
        audit_log=lambda e: log.append(e),
    )
    assert len(log) == 1
    assert log[0]["routed"] is False


# ---------------------------------------------------------------------
# Parity tests — the same input through all three caller shapes
# (active-id / picker / auto-spawn) produces consistent observables.
# ---------------------------------------------------------------------


def test_all_three_callers_same_decision_for_active_id() -> None:
    """The Tk surface's call (active_session_id="sess-1"), the
    terminal/Streamlit node's call (target via composition node), and
    the website's call (default_target_picker→sess-1) ALL converge
    on the same routing decision. Validates the central consolidation
    invariant.
    """
    sm = _StubSM([_StubRec("sess-1", session_type="workflow_management")])

    # Tk-shape call.
    r_tk = chat_router_core.route_chat(
        "test", session_manager=sm, active_session_id="sess-1",
    )

    # Streamlit chat_router node-shape call (passes target via the
    # active_session_id slot, since the node-type's _send extracts
    # target the same way).
    sm2 = _StubSM([_StubRec("sess-1", session_type="workflow_management")])
    r_node = chat_router_core.route_chat(
        "test", session_manager=sm2, active_session_id="sess-1",
    )

    # Website-shape call (picker resolves to sess-1).
    sm3 = _StubSM([_StubRec("sess-1", session_type="workflow_management")])
    r_web = chat_router_core.route_chat(
        "test", session_manager=sm3,
        default_target_picker=lambda ss: ss[0] if ss else None,
    )

    # All three should produce identical (routed, target,
    # delivered_to). The reason string format is preserved across
    # callers (the legacy three implementations had divergent reason
    # strings; the consolidation normalizes them).
    for r in (r_tk, r_node, r_web):
        assert r["routed"] is True
        assert r["target"] == "sess-1"
        assert r["delivered_to"] == ["sess-1"]
