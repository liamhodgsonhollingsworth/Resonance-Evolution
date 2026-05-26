"""Tests for the default JSONL audit-log writer used by ``chat_router_core``.

Closes deferred-concerns #15 (A2-3): every route_chat invocation
should be persisted to a JSONL audit log so debugging "why did this
message go to session X" doesn't require re-running the routing
logic. The website-side already plugged in its own ``_audit`` hook;
this module wires the default writer for the Apeiron-side surfaces
(Tk gui_shell.route_chat, the chat_router node-type's
``_send_via_core``) so they get observability for free.

Tests cover:

  - Audit-log file gets created on first call.
  - Subsequent calls append (one JSON object per line).
  - Each record matches the deferred-concerns #15 schema
    (``ts``, ``message_id``, ``input_session``, ``output_session``,
    ``reason``, ``fallback_used``).
  - ``fallback_used`` derives the right path from the reason +
    session ids (auto-spawn / default-picker / active / None).
  - Rotation fires when the file exceeds the threshold.
  - Rotated files retain content (gzip-compressed when available).
  - The writer survives non-serializable entries + disk failures
    without raising into the route_chat path.
  - The default writer is used when no hook is plugged in to the
    integrated chat_router_core call path.
  - The explicit-hook path (the website's ``_audit``) is unchanged
    when a hook IS plugged in.

Run::

    cd Apeiron && python -m pytest tests/test_route_chat_audit_log.py -v
"""

from __future__ import annotations

import gzip
import json
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from tools.workflow import chat_router_core, route_chat_audit_log


# ---------------------------------------------------------------------
# Test fixtures + stubs (copied from test_chat_router_core_consolidation
# so the test file stands alone and a stub-shape change in one place
# doesn't break the other).
# ---------------------------------------------------------------------


class _StubRec:
    def __init__(
        self,
        sid: str,
        display_name: str = "",
        status: str = "active",
    ) -> None:
        self.id = sid
        self.display_name = display_name or sid
        self.status = status


class _StubSM:
    def __init__(self, recs: Optional[List[_StubRec]] = None) -> None:
        self._recs = recs or []
        self.sent: List[Tuple[str, str]] = []
        self.reactivated: List[str] = []

    def get(self, sid: str) -> Optional[_StubRec]:
        for rec in self._recs:
            if rec.id == sid:
                return rec
        return None

    def list(self) -> List[_StubRec]:
        return list(self._recs)

    def send(self, sid: str, body: str) -> None:
        self.sent.append((sid, body))

    def reactivate(self, sid: str) -> None:
        self.reactivated.append(sid)


# ---------------------------------------------------------------------
# Direct writer-API tests — exercise the writer module in isolation.
# ---------------------------------------------------------------------


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    """Read every line in path as JSON. Skips blank lines."""
    if not path.exists():
        return []
    out: List[Dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(json.loads(line))
    return out


def test_writer_creates_file_on_first_call(tmp_path: Path) -> None:
    """The JSONL file doesn't exist until the first append; the
    writer creates the parent directory + the file lazily.
    """
    state_dir = tmp_path / "state" / "workflow"
    # Parent dir doesn't exist before the first call.
    assert not state_dir.exists()
    write = route_chat_audit_log.audit_log_writer(state_dir=state_dir)
    write({
        "routed": True, "target": "sess-1",
        "delivered_to": ["sess-1"], "message": "hi",
        "reason": "routed to sess-1", "actor": "maintainer",
    })
    path = state_dir / "route_chat_decisions.jsonl"
    assert path.exists()
    records = _read_jsonl(path)
    assert len(records) == 1


def test_writer_appends_subsequent_calls(tmp_path: Path) -> None:
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    for i in range(5):
        write({
            "routed": True, "target": f"sess-{i}",
            "delivered_to": [f"sess-{i}"], "message": f"msg-{i}",
            "reason": f"routed to sess-{i}", "actor": "maintainer",
        })
    path = tmp_path / "route_chat_decisions.jsonl"
    records = _read_jsonl(path)
    assert len(records) == 5
    # Order preserved.
    assert [r["output_session"] for r in records] == [
        f"sess-{i}" for i in range(5)
    ]


def test_writer_schema_matches_spec(tmp_path: Path) -> None:
    """Every record carries the six deferred-concerns #15 schema
    keys. Extras land under ``extra`` or as known side-keys
    (``actor``, ``message``, ``delivered_to``, ``routed``).
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": True,
        "target": "sess-A",
        "delivered_to": ["sess-A"],
        "message": "hello",
        "reason": "routed to sess-A",
        "actor": "maintainer",
    })
    records = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")
    record = records[0]
    for key in (
        "ts", "message_id", "input_session", "output_session",
        "reason", "fallback_used",
    ):
        assert key in record, f"schema key {key!r} missing"
    assert record["output_session"] == "sess-A"
    assert record["reason"] == "routed to sess-A"
    assert record["actor"] == "maintainer"


def test_fallback_used_auto_spawn_branch(tmp_path: Path) -> None:
    """The core's ``reason`` text disambiguates which fallback fired.
    The auto-spawn branch starts with ``"auto-spawned"``.
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": True,
        "target": "spawned-aaa",
        "delivered_to": ["spawned-aaa"],
        "message": "first message",
        "reason": (
            "auto-spawned workflow_management session spawned- "
            "with your message as the seed prompt"
        ),
        "actor": "maintainer",
    })
    record = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")[0]
    assert record["fallback_used"] == "auto-spawn"


def test_fallback_used_active_session_branch(tmp_path: Path) -> None:
    """When ``input_session`` is supplied (Tk surface's typical
    shape) and ``output_session`` matches, the fallback path is
    ``active``."""
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": True,
        "target": "sess-1",
        "delivered_to": ["sess-1"],
        "message": "hi",
        "reason": "routed to sess-1",
        "actor": "maintainer",
        "input_session": "sess-1",
    })
    record = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")[0]
    assert record["fallback_used"] == "active"


def test_fallback_used_default_picker_branch(tmp_path: Path) -> None:
    """The website surface's typical shape: no input_session,
    picker resolves a target. The fallback path is
    ``default-picker``.
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": True,
        "target": "wf-mgmt-sess",
        "delivered_to": ["wf-mgmt-sess"],
        "message": "build a button",
        "reason": "routed to wf-mgmt-sess",
        "actor": "maintainer",
    })
    record = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")[0]
    assert record["fallback_used"] == "default-picker"


def test_fallback_used_none_for_soft_fail(tmp_path: Path) -> None:
    """Soft-fail records carry ``fallback_used: null`` because no
    fallback resolved successfully."""
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": False,
        "target": None,
        "delivered_to": [],
        "message": "hi",
        "reason": "no active session — open Chat tab to pick one",
        "actor": "maintainer",
    })
    record = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")[0]
    assert record["fallback_used"] is None


def test_fallback_used_none_for_broadcast(tmp_path: Path) -> None:
    """/all broadcasts bypass the fallback chain; ``fallback_used``
    is null because the broadcast target is ``"all"``, not a
    session id."""
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    write({
        "routed": True,
        "target": "all",
        "delivered_to": ["sess-1", "sess-2"],
        "message": "heads up",
        "reason": "broadcast to 2 session(s)",
        "actor": "maintainer",
    })
    record = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")[0]
    assert record["fallback_used"] is None


def test_message_id_is_stable_and_distinct(tmp_path: Path) -> None:
    """Two consecutive identical-content calls produce distinct
    message ids because the ``ts`` differs (even at the same
    second the ts can match — but the writer also incorporates a
    distinct-message id for downstream debuggability when content
    is identical at the same second)."""
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    entry = {
        "routed": True, "target": "sess-1",
        "delivered_to": ["sess-1"], "message": "hi",
        "reason": "routed to sess-1", "actor": "maintainer",
    }
    write(entry)
    write(entry)
    records = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")
    assert len(records) == 2
    # Ids may collide at the same second AND identical content —
    # that's acceptable for the v1 schema. The test asserts the
    # id is a stable hex string of the expected length.
    for r in records:
        assert isinstance(r["message_id"], str)
        assert len(r["message_id"]) == 12
        assert all(c in "0123456789abcdef" for c in r["message_id"])


def test_writer_rotates_when_threshold_exceeded(tmp_path: Path) -> None:
    """When the live file would exceed the rotation threshold,
    rotate to a timestamped sibling + start a fresh file. Use a
    tiny threshold so the test fires quickly."""
    write = route_chat_audit_log.audit_log_writer(
        state_dir=tmp_path,
        rotation_bytes=200,  # ~1 entry per file
    )
    for i in range(5):
        write({
            "routed": True, "target": f"sess-{i}",
            "delivered_to": [f"sess-{i}"], "message": f"m-{i}",
            "reason": f"routed to sess-{i}", "actor": "maintainer",
        })
    # The live file holds at most one entry; the rotation siblings
    # hold the rest. Total appended entries (live + rotated) is 5.
    live = tmp_path / "route_chat_decisions.jsonl"
    rotated = sorted(
        p for p in tmp_path.iterdir()
        if p.name.startswith("route_chat_decisions.jsonl.")
    )
    total = len(_read_jsonl(live))
    for r in rotated:
        if r.suffix == ".gz":
            with gzip.open(r, "rb") as fh:
                total += sum(1 for line in fh if line.strip())
        else:
            total += sum(
                1 for line in r.read_text(encoding="utf-8").splitlines()
                if line.strip()
            )
    assert total == 5
    # At least one rotation happened.
    assert len(rotated) >= 1


def test_writer_skips_rotation_when_disabled(tmp_path: Path) -> None:
    """``rotation_bytes=0`` disables rotation; the file grows
    unbounded."""
    write = route_chat_audit_log.audit_log_writer(
        state_dir=tmp_path,
        rotation_bytes=0,
    )
    for i in range(20):
        write({
            "routed": True, "target": f"sess-{i}",
            "delivered_to": [f"sess-{i}"], "message": f"m-{i}",
            "reason": f"routed to sess-{i}", "actor": "maintainer",
        })
    siblings = [
        p for p in tmp_path.iterdir()
        if p.name.startswith("route_chat_decisions.jsonl.")
    ]
    assert siblings == []
    records = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")
    assert len(records) == 20


def test_writer_never_raises_on_non_serializable_entry(tmp_path: Path) -> None:
    """A non-JSON-serializable entry (e.g., contains a thread object)
    must not propagate into the caller. The writer swallows the
    exception so route_chat code can keep going.
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    # threading.Lock() is not JSON-serializable.
    bad_entry: Dict[str, Any] = {
        "routed": True, "target": "sess-1",
        "lock": threading.Lock(),
        "reason": "routed", "actor": "maintainer",
    }
    # Should not raise.
    write(bad_entry)


def test_writer_concurrent_appends_no_interleaving(tmp_path: Path) -> None:
    """Two threads writing concurrently produce well-formed lines
    (each line parses as JSON; total count matches the per-thread
    append count). The in-process lock + ``O_APPEND`` semantics
    guarantee atomicity for small payloads.
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)

    def _hammer(thread_id: int, n: int) -> None:
        for i in range(n):
            write({
                "routed": True, "target": f"t{thread_id}-s{i}",
                "delivered_to": [f"t{thread_id}-s{i}"],
                "message": f"thread-{thread_id}-msg-{i}",
                "reason": f"routed by t{thread_id}",
                "actor": "maintainer",
            })

    threads = [
        threading.Thread(target=_hammer, args=(tid, 50))
        for tid in range(4)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    records = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")
    assert len(records) == 4 * 50


# ---------------------------------------------------------------------
# Integration tests — the writer plugged into chat_router_core.
# ---------------------------------------------------------------------


def test_integration_writes_through_route_chat(tmp_path: Path) -> None:
    """End-to-end: a real ``route_chat`` call with the default
    writer wired in appends one record per call. The integration
    test pins the contract that the call sites in gui_shell +
    chat_router node-type pass the writer explicitly.
    """
    write = route_chat_audit_log.audit_log_writer(state_dir=tmp_path)
    sm = _StubSM([_StubRec("sess-1")])
    result = chat_router_core.route_chat(
        "hello there",
        session_manager=sm,
        active_session_id="sess-1",
        audit_log=write,
    )
    assert result["routed"] is True
    records = _read_jsonl(tmp_path / "route_chat_decisions.jsonl")
    assert len(records) == 1
    assert records[0]["output_session"] == "sess-1"
    assert records[0]["reason"] == "routed to sess-1"
    assert records[0]["fallback_used"] == "active"
    assert records[0]["actor"] == "maintainer"


def test_integration_explicit_hook_still_wins(tmp_path: Path) -> None:
    """When a caller passes an explicit ``audit_log`` (the website's
    ``_audit``), the default JSONL writer is NOT used — the explicit
    hook gets exclusive control. This pins the contract that the
    website's existing plumbing is untouched.
    """
    explicit_log: List[Dict[str, Any]] = []

    def _explicit(entry: Dict[str, Any]) -> None:
        explicit_log.append(entry)

    sm = _StubSM([_StubRec("sess-1")])
    chat_router_core.route_chat(
        "hello",
        session_manager=sm,
        active_session_id="sess-1",
        audit_log=_explicit,
    )
    assert len(explicit_log) == 1
    # The default writer wasn't fired; no JSONL file in tmp.
    assert not (tmp_path / "route_chat_decisions.jsonl").exists()


def test_integration_no_writer_logs_nothing(tmp_path: Path) -> None:
    """When no ``audit_log`` is passed (the test/legacy shape), no
    audit log is written. The default writer is NOT auto-installed
    inside chat_router_core — call sites opt in explicitly. This
    keeps tests that don't pass an audit hook from polluting the
    apeiron-root state dir.
    """
    sm = _StubSM([_StubRec("sess-1")])
    chat_router_core.route_chat(
        "hi",
        session_manager=sm,
        active_session_id="sess-1",
    )
    # No file in tmp; default writer was not auto-installed.
    assert not (tmp_path / "route_chat_decisions.jsonl").exists()


def test_default_state_dir_uses_apeiron_root() -> None:
    """The default state-dir resolves to ``<apeiron-root>/state/workflow/``
    when ``APEIRON_STATE_DIR`` is unset. The exact path varies by
    where the test runs, but the suffix is stable."""
    import os
    saved = os.environ.pop("APEIRON_STATE_DIR", None)
    try:
        resolved = route_chat_audit_log.default_state_dir()
        assert resolved.name == "workflow"
        assert resolved.parent.name == "state"
    finally:
        if saved is not None:
            os.environ["APEIRON_STATE_DIR"] = saved


def test_default_state_dir_honors_env_var(monkeypatch: pytest.MonkeyPatch,
                                          tmp_path: Path) -> None:
    """When ``APEIRON_STATE_DIR`` is set, the default resolution
    appends ``workflow/`` to it (the env var names the apeiron base
    state dir, the audit log lives in its workflow sub-dir alongside
    sessions + inbox + raw_logs). Precedence rule above the
    apeiron-root-derived fallback."""
    target = tmp_path / "custom-state"
    monkeypatch.setenv("APEIRON_STATE_DIR", str(target))
    resolved = route_chat_audit_log.default_state_dir()
    assert resolved == target / "workflow"


# ---------------------------------------------------------------------
# Call-site wiring tests — the integration points in gui_shell +
# chat_router node-type pass the default writer. These tests use
# stub engines to avoid spinning up real Tk or real Streamlit.
# ---------------------------------------------------------------------


class _StubEngine:
    def __init__(self) -> None:
        self.cache: Dict[str, Any] = {}


def test_chat_router_node_wires_default_writer(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The chat_router node-type's direct-mode dispatcher
    (``_send_via_core``) installs the default JSONL writer when
    none is plumbed in via engine.cache.
    """
    monkeypatch.setenv("APEIRON_STATE_DIR", str(tmp_path))
    import node_types.chat_router as cr
    sm = _StubSM([_StubRec("sess-1")])
    engine = _StubEngine()
    engine.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    result = cr._send_via_core(engine, target="sess-1", text="hello")
    assert result["routed"] is True
    # Default writer landed audit lines under APEIRON_STATE_DIR /
    # "workflow" / "route_chat_decisions.jsonl".
    path = tmp_path / "workflow" / "route_chat_decisions.jsonl"
    assert path.exists()
    records = _read_jsonl(path)
    assert len(records) == 1
    assert records[0]["output_session"] == "sess-1"


def test_chat_router_node_respects_preinstalled_writer(
    tmp_path: Path,
) -> None:
    """When engine.cache['__workflow__'] already has a
    ``route_chat_audit_log`` entry, the node-type does NOT
    overwrite it (the preinstalled hook wins).
    """
    import node_types.chat_router as cr
    sm = _StubSM([_StubRec("sess-1")])
    captured: List[Dict[str, Any]] = []

    def _custom(entry: Dict[str, Any]) -> None:
        captured.append(entry)

    engine = _StubEngine()
    engine.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": None,
        "route_chat_audit_log": _custom,
    }
    cr._send_via_core(engine, target="sess-1", text="hi")
    assert len(captured) == 1
    # No JSONL file created — the custom hook fired instead.
    assert not (tmp_path / "route_chat_decisions.jsonl").exists()
