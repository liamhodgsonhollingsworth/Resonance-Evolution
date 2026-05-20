"""
Tests for the active-sessions discovery primitive — SPEC-079.

Covers register / heartbeat / unregister / list_active_sessions /
get_active_session, stale detection, atomic write semantics, the
text-API ``list-sessions`` command, the Sessions view registered in
default_view_registry, and the SessionManager integration that
auto-registers spawned sessions.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tools.active_sessions import (
    ActiveSession,
    get_active_session,
    heartbeat,
    list_active_sessions,
    register_session,
    registry_path,
    unregister_session,
)


# ---------------------------------------------------------------------------
# Registry file location.
# ---------------------------------------------------------------------------


def test_registry_path_default(tmp_path):
    p = registry_path(tmp_path)
    assert p == tmp_path / "active_sessions.json"


def test_registry_path_none_fallback():
    p = registry_path(None)
    assert p.name == "active_sessions.json"


# ---------------------------------------------------------------------------
# register_session.
# ---------------------------------------------------------------------------


def test_register_creates_entry(tmp_path):
    s = register_session(
        "session-1", "apeiron", "implementation",
        focus="building view registry",
        state_dir=tmp_path,
    )
    assert s.id == "session-1"
    assert s.project == "apeiron"
    assert s.session_type == "implementation"
    assert s.focus == "building view registry"
    assert s.last_seen
    # File is on disk.
    path = registry_path(tmp_path)
    assert path.exists()


def test_register_persists_to_disk(tmp_path):
    register_session("s-1", "p1", "t1", state_dir=tmp_path)
    raw = json.loads(registry_path(tmp_path).read_text(encoding="utf-8"))
    assert isinstance(raw, list)
    assert len(raw) == 1
    assert raw[0]["id"] == "s-1"


def test_register_idempotent(tmp_path):
    """Two register calls with the same id update one entry,
    not create duplicates."""
    register_session("s-1", "p1", "t1", focus="first", state_dir=tmp_path)
    register_session("s-1", "p1", "t1", focus="second", state_dir=tmp_path)
    sessions = list_active_sessions(state_dir=tmp_path)
    assert len(sessions) == 1
    assert sessions[0].focus == "second"


def test_register_multiple_distinct_sessions(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    register_session("s-2", "p", "t", state_dir=tmp_path)
    register_session("s-3", "p", "t", state_dir=tmp_path)
    sessions = list_active_sessions(state_dir=tmp_path)
    assert len(sessions) == 3


def test_register_preserves_started_at_on_replace(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    original = list_active_sessions(state_dir=tmp_path)[0]
    time.sleep(0.05)
    # Second register should update last_seen but keep started_at.
    register_session("s-1", "p", "t", state_dir=tmp_path)
    after = list_active_sessions(state_dir=tmp_path)[0]
    assert after.started_at == original.started_at


def test_register_records_pid_and_cwd(tmp_path):
    register_session(
        "s-1", "p", "t", pid=12345, cwd="/some/path", state_dir=tmp_path,
    )
    s = list_active_sessions(state_dir=tmp_path)[0]
    assert s.pid == 12345
    assert s.cwd == "/some/path"


def test_register_with_metadata(tmp_path):
    register_session(
        "s-1", "p", "t",
        metadata={"branch": "claude/spec-079"},
        state_dir=tmp_path,
    )
    s = list_active_sessions(state_dir=tmp_path)[0]
    assert s.metadata == {"branch": "claude/spec-079"}


# ---------------------------------------------------------------------------
# heartbeat.
# ---------------------------------------------------------------------------


def test_heartbeat_updates_last_seen(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    initial = list_active_sessions(state_dir=tmp_path)[0].last_seen
    time.sleep(1.01)
    assert heartbeat("s-1", state_dir=tmp_path) is True
    after = list_active_sessions(state_dir=tmp_path)[0].last_seen
    assert after > initial


def test_heartbeat_can_update_focus(tmp_path):
    register_session("s-1", "p", "t", focus="step 1", state_dir=tmp_path)
    heartbeat("s-1", focus="step 2", state_dir=tmp_path)
    s = list_active_sessions(state_dir=tmp_path)[0]
    assert s.focus == "step 2"


def test_heartbeat_unknown_returns_false(tmp_path):
    assert heartbeat("nonexistent", state_dir=tmp_path) is False


def test_heartbeat_preserves_other_fields(tmp_path):
    register_session(
        "s-1", "apeiron", "implementation",
        focus="initial",
        pid=999,
        cwd="/foo",
        state_dir=tmp_path,
    )
    heartbeat("s-1", focus="updated", state_dir=tmp_path)
    s = list_active_sessions(state_dir=tmp_path)[0]
    assert s.project == "apeiron"
    assert s.session_type == "implementation"
    assert s.pid == 999
    assert s.cwd == "/foo"


# ---------------------------------------------------------------------------
# unregister_session.
# ---------------------------------------------------------------------------


def test_unregister_removes_entry(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    register_session("s-2", "p", "t", state_dir=tmp_path)
    assert unregister_session("s-1", state_dir=tmp_path) is True
    sessions = list_active_sessions(state_dir=tmp_path)
    assert len(sessions) == 1
    assert sessions[0].id == "s-2"


def test_unregister_unknown_returns_false(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    assert unregister_session("nonexistent", state_dir=tmp_path) is False
    # Other entries untouched.
    assert len(list_active_sessions(state_dir=tmp_path)) == 1


def test_unregister_no_registry_returns_false(tmp_path):
    """When no registry file exists, unregister is a no-op."""
    assert unregister_session("s-1", state_dir=tmp_path) is False


# ---------------------------------------------------------------------------
# list_active_sessions and stale filtering.
# ---------------------------------------------------------------------------


def test_list_empty_when_no_file(tmp_path):
    assert list_active_sessions(state_dir=tmp_path) == []


def test_list_returns_freshest_first(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    time.sleep(1.01)
    register_session("s-2", "p", "t", state_dir=tmp_path)
    sessions = list_active_sessions(state_dir=tmp_path)
    # s-2 was last registered → should be first.
    assert sessions[0].id == "s-2"
    assert sessions[1].id == "s-1"


def test_stale_filter_drops_old_entries(tmp_path):
    """An entry with last_seen 20 minutes ago is filtered out by the
    default 10-min threshold."""
    # Write a registry file with one stale entry.
    stale_ts = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat(timespec="seconds")
    fresh_ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    payload = [
        {"id": "stale", "project": "p", "session_type": "t",
         "focus": "", "last_seen": stale_ts, "started_at": stale_ts,
         "pid": None, "cwd": "", "metadata": {}},
        {"id": "fresh", "project": "p", "session_type": "t",
         "focus": "", "last_seen": fresh_ts, "started_at": fresh_ts,
         "pid": None, "cwd": "", "metadata": {}},
    ]
    registry_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    registry_path(tmp_path).write_text(json.dumps(payload), encoding="utf-8")
    sessions = list_active_sessions(state_dir=tmp_path)
    assert [s.id for s in sessions] == ["fresh"]


def test_stale_filter_include_stale_keeps_old(tmp_path):
    stale_ts = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat(timespec="seconds")
    payload = [
        {"id": "stale", "project": "p", "session_type": "t",
         "focus": "", "last_seen": stale_ts, "started_at": stale_ts,
         "pid": None, "cwd": "", "metadata": {}},
    ]
    registry_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    registry_path(tmp_path).write_text(json.dumps(payload), encoding="utf-8")
    sessions = list_active_sessions(state_dir=tmp_path, include_stale=True)
    assert len(sessions) == 1
    assert sessions[0].is_stale


def test_stale_filter_custom_threshold(tmp_path):
    """A 1-minute threshold filters anything older than 1 minute."""
    almost_stale = (datetime.now(timezone.utc) - timedelta(seconds=70)).isoformat(timespec="seconds")
    payload = [
        {"id": "x", "project": "p", "session_type": "t",
         "focus": "", "last_seen": almost_stale, "started_at": almost_stale,
         "pid": None, "cwd": "", "metadata": {}},
    ]
    registry_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    registry_path(tmp_path).write_text(json.dumps(payload), encoding="utf-8")
    assert list_active_sessions(state_dir=tmp_path, stale_after_min=1.0) == []
    sessions = list_active_sessions(state_dir=tmp_path, stale_after_min=2.0)
    assert len(sessions) == 1


def test_list_skips_unknown_extra_fields(tmp_path):
    """Forward-compat: a registry written by a newer client with
    extra fields can be read by this client without crashing."""
    fresh_ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    payload = [
        {
            "id": "x",
            "project": "p",
            "session_type": "t",
            "focus": "",
            "last_seen": fresh_ts,
            "started_at": fresh_ts,
            "pid": None,
            "cwd": "",
            "metadata": {},
            "future_field": "ignored",
            "another_future_field": [1, 2, 3],
        },
    ]
    registry_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    registry_path(tmp_path).write_text(json.dumps(payload), encoding="utf-8")
    sessions = list_active_sessions(state_dir=tmp_path)
    assert len(sessions) == 1


def test_list_recovers_from_corrupted_file(tmp_path):
    """A malformed JSON file must not block discovery."""
    p = registry_path(tmp_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("{ not json", encoding="utf-8")
    # Should return [] not raise.
    assert list_active_sessions(state_dir=tmp_path) == []


# ---------------------------------------------------------------------------
# ActiveSession dataclass.
# ---------------------------------------------------------------------------


def test_active_session_is_stale_default():
    s = ActiveSession(
        id="x", project="p", session_type="t",
        last_seen="2020-01-01T00:00:00+00:00",
    )
    assert s.is_stale is True


def test_active_session_last_seen_age():
    s = ActiveSession(
        id="x", project="p", session_type="t",
        last_seen=datetime.now(timezone.utc).isoformat(timespec="seconds"),
    )
    assert s.last_seen_age_seconds() < 5.0


def test_active_session_missing_last_seen_is_stale():
    s = ActiveSession(id="x", project="p", session_type="t", last_seen="")
    assert s.last_seen_age_seconds() == float("inf")
    assert s.is_stale is True


def test_active_session_malformed_last_seen_is_stale():
    s = ActiveSession(id="x", project="p", session_type="t", last_seen="not-a-date")
    assert s.last_seen_age_seconds() == float("inf")
    assert s.is_stale is True


# ---------------------------------------------------------------------------
# get_active_session.
# ---------------------------------------------------------------------------


def test_get_active_session_found(tmp_path):
    register_session("s-1", "p", "t", state_dir=tmp_path)
    s = get_active_session("s-1", state_dir=tmp_path)
    assert s is not None
    assert s.id == "s-1"


def test_get_active_session_not_found(tmp_path):
    assert get_active_session("nonexistent", state_dir=tmp_path) is None


# ---------------------------------------------------------------------------
# text-API list-sessions command.
# ---------------------------------------------------------------------------


def test_text_api_list_sessions(tmp_path):
    """The text-API list-sessions command consults the registry
    via engine.active_sessions_state_dir."""
    from engine.core import Engine
    from tools.text_test import dispatch_command

    register_session("s-1", "apeiron", "implementation",
                     focus="working", state_dir=tmp_path)
    e = Engine(root_dir=Path("."))
    e.active_sessions_state_dir = tmp_path
    msg, _ = dispatch_command(e, "list-sessions")
    assert "s-1" in msg
    assert "apeiron" in msg
    assert "implementation" in msg


def test_text_api_list_sessions_empty(tmp_path):
    from engine.core import Engine
    from tools.text_test import dispatch_command

    e = Engine(root_dir=Path("."))
    e.active_sessions_state_dir = tmp_path
    msg, _ = dispatch_command(e, "list-sessions")
    assert "no active sessions" in msg


# ---------------------------------------------------------------------------
# Sessions view registered in default_view_registry.
# ---------------------------------------------------------------------------


def test_default_registry_has_sessions_view():
    from tools.workflow_gui.view_registry import default_view_registry

    reg = default_view_registry()
    spec = reg.get("Sessions")
    assert spec is not None
    assert spec.kind == "dynamic"
    assert spec.items_provider is not None


def test_sessions_view_items_empty_when_no_registry(tmp_path):
    """When no registry file exists, the Sessions view returns one
    synthetic 'no active sessions' row."""
    from tools.gui_test_driver import GuiDriver

    drv = GuiDriver().build()
    drv.shell.engine.active_sessions_state_dir = tmp_path
    items = drv.items_for_tab("Sessions")
    assert len(items) == 1
    assert "no active sessions" in items[0]["title"]


def test_sessions_view_items_with_registered_session(tmp_path):
    from tools.gui_test_driver import GuiDriver

    register_session(
        "s-1", "apeiron", "implementation",
        focus="building SPEC-079", state_dir=tmp_path,
    )
    drv = GuiDriver().build()
    drv.shell.engine.active_sessions_state_dir = tmp_path
    items = drv.items_for_tab("Sessions")
    assert any(it["id"] == "s-1" for it in items)


def test_sessions_view_status_stale(tmp_path):
    """A stale session shows up with status='alert' when
    include_stale would surface it, but the default 10-min filter
    hides it from the items list."""
    from tools.gui_test_driver import GuiDriver

    # Stale entry written directly.
    stale_ts = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat(timespec="seconds")
    payload = [
        {"id": "stale-x", "project": "p", "session_type": "t",
         "focus": "", "last_seen": stale_ts, "started_at": stale_ts,
         "pid": None, "cwd": "", "metadata": {}},
    ]
    registry_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    registry_path(tmp_path).write_text(json.dumps(payload), encoding="utf-8")

    drv = GuiDriver().build()
    drv.shell.engine.active_sessions_state_dir = tmp_path
    items = drv.items_for_tab("Sessions")
    # Default 10-min stale filter hides the stale entry → the
    # 'no active sessions' placeholder is returned.
    assert len(items) == 1
    assert items[0]["id"] == "sessions-empty"


# ---------------------------------------------------------------------------
# Dynamic view kind validation.
# ---------------------------------------------------------------------------


def test_dynamic_view_kind_is_legal():
    from tools.workflow_gui.view_registry import ViewRegistry, ViewSpec

    reg = ViewRegistry()
    reg.register(
        ViewSpec(
            name="X",
            kind="dynamic",
            items_provider=lambda _engine: [{"id": "1", "title": "row"}],
        )
    )
    assert reg.names() == ["X"]


def test_dynamic_view_renders_provider_items():
    """The provider callback returns items that flow through to
    items_for_tab."""
    from tools.gui_test_driver import GuiDriver
    from tools.workflow_gui.view_registry import ViewSpec

    drv = GuiDriver().build()
    drv.register_view(
        ViewSpec(
            name="ProviderTest",
            kind="dynamic",
            items_provider=lambda _engine: [
                {"id": "row-1", "title": "first", "status": "ok", "actions": ["expand"]},
                {"id": "row-2", "title": "second", "status": "ok", "actions": ["expand"]},
            ],
        )
    )
    items = drv.items_for_tab("ProviderTest")
    assert len(items) == 2
    assert items[0]["title"] == "first"


def test_dynamic_view_provider_exception_handled():
    """A raising provider is captured as a one-row alert; the GUI
    must never crash on a bad provider."""
    from tools.gui_test_driver import GuiDriver
    from tools.workflow_gui.view_registry import ViewSpec

    def bad_provider(_engine):
        raise RuntimeError("provider failure")

    drv = GuiDriver().build()
    drv.register_view(
        ViewSpec(name="Bad", kind="dynamic", items_provider=bad_provider)
    )
    items = drv.items_for_tab("Bad")
    assert len(items) == 1
    assert items[0]["status"] == "alert"
    assert "provider failure" in items[0]["body"]
