"""Tests for the session-* node cluster (lister/resolver/sender/spawner/archiver/target).

The cluster decomposes what would have been one large session_controller
into six small composite logic-nodes. Each node has 1-2 verbs and a
minimal state surface. The cluster pairs with chat_router_main to give
the surfaces a renderer-neutral way to operate sessions.

This file exercises the unique semantics of each node directly via
dispatch_action; cross-node integration is covered by
test_workflow_streamlit_commands.py.
"""

from __future__ import annotations

import dataclasses
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

from engine import actions as engine_actions
from engine.core import Engine


@dataclasses.dataclass
class FakeRecord:
    id: str
    display_name: str
    session_type: str = "general"
    status: str = "active"
    cwd: str = "."
    spawned_at: str = "2026-05-21T00:00:00Z"
    last_active_at: str = "2026-05-21T00:00:00Z"
    concerns: List[str] = dataclasses.field(default_factory=list)


class FakeSessionManager:
    def __init__(self, records: Optional[List[FakeRecord]] = None) -> None:
        self.records: List[FakeRecord] = records or []
        self.sent: List = []
        self.archived: List[str] = []
        self.spawned: List[Dict[str, Any]] = []
        self.spawn_returns_id: str = "new-session-id"

    def list(self) -> List[FakeRecord]:
        return list(self.records)

    def get(self, sid: str) -> Optional[FakeRecord]:
        for r in self.records:
            if r.id == sid:
                return r
        return None

    def send(self, sid: str, body: str) -> None:
        self.sent.append((sid, body))

    def archive(self, sid: str) -> None:
        self.archived.append(sid)
        for r in self.records:
            if r.id == sid:
                r.status = "archived"

    def spawn(self, **kw: Any) -> FakeRecord:
        self.spawned.append(kw)
        rec = FakeRecord(
            id=self.spawn_returns_id,
            display_name=kw.get("display_name") or "new",
            session_type=kw.get("session_type") or "general",
        )
        self.records.append(rec)
        return rec


@pytest.fixture
def engine_with_cluster(tmp_path: Path) -> Engine:
    apeiron_root = Path(__file__).resolve().parents[1]
    engine = Engine(root_dir=apeiron_root)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "session_lister_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"session_lister_main","type":"SessionLister","params":{}},
            {"id":"session_resolver_main","type":"SessionResolver","params":{}},
            {"id":"session_sender_main","type":"SessionSender","params":{}},
            {"id":"session_spawner_main","type":"SessionSpawner","params":{}},
            {"id":"session_archiver_main","type":"SessionArchiver","params":{}},
            {"id":"session_target_main","type":"SessionTarget","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


# ----- SessionLister -----


def test_lister_returns_records(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([
        FakeRecord(id="aaaaaaaa-1111", display_name="alpha"),
        FakeRecord(id="bbbbbbbb-2222", display_name="beta"),
    ])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_lister_main", "refresh", payload={}
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_lister_main")
    assert len(view["sessions"]) == 2
    assert {s["id"] for s in view["sessions"]} == {"aaaaaaaa-1111", "bbbbbbbb-2222"}
    assert view["error"] is None


def test_lister_empty_when_no_session_manager(engine_with_cluster: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_cluster, "session_lister_main", "refresh", payload={}
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_lister_main")
    assert view["sessions"] == []
    assert view["error"] == "no session_manager"


# ----- SessionResolver -----


def test_resolver_exact_id(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([FakeRecord(id="aaaaaaaa-1111", display_name="alpha")])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_resolver_main", "resolve",
        payload={"name_or_id": "aaaaaaaa-1111"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_resolver_main")
    assert view["last_resolution"]["resolved"] is True
    assert view["last_resolution"]["session_id"] == "aaaaaaaa-1111"
    assert view["last_resolution"]["reason"] == "exact id"


def test_resolver_unique_name(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([
        FakeRecord(id="aaaaaaaa-1111", display_name="alpha"),
        FakeRecord(id="bbbbbbbb-2222", display_name="beta"),
    ])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_resolver_main", "resolve",
        payload={"name_or_id": "alpha"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_resolver_main")
    assert view["last_resolution"]["resolved"] is True
    assert view["last_resolution"]["session_id"] == "aaaaaaaa-1111"


def test_resolver_ambiguous_name(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([
        FakeRecord(id="aaaaaaaa-1111", display_name="dup"),
        FakeRecord(id="bbbbbbbb-2222", display_name="dup"),
    ])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_resolver_main", "resolve",
        payload={"name_or_id": "dup"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_resolver_main")
    assert view["last_resolution"]["resolved"] is False
    assert len(view["last_resolution"]["candidates"]) == 2


def test_resolver_unique_id_prefix(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([
        FakeRecord(id="aaaaaaaa-1111", display_name="alpha"),
        FakeRecord(id="bbbbbbbb-2222", display_name="beta"),
    ])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_resolver_main", "resolve",
        payload={"name_or_id": "aaaaaaaa"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_resolver_main")
    assert view["last_resolution"]["resolved"] is True
    assert view["last_resolution"]["session_id"] == "aaaaaaaa-1111"


def test_resolver_unknown(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([FakeRecord(id="aaaaaaaa-1111", display_name="alpha")])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_resolver_main", "resolve",
        payload={"name_or_id": "nope"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_resolver_main")
    assert view["last_resolution"]["resolved"] is False
    assert "no session matches" in view["last_resolution"]["reason"]


# ----- SessionSender -----


def test_sender_delivers(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([FakeRecord(id="sid-1", display_name="x")])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_sender_main", "send",
        payload={"session_id": "sid-1", "body": "hi"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_sender_main")
    assert view["last_send"]["sent"] is True
    assert sm.sent == [("sid-1", "hi")]


def test_sender_rejects_empty(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager()
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_sender_main", "send",
        payload={"session_id": "", "body": "hi"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_sender_main")
    assert view["last_send"]["sent"] is False
    assert "empty session_id" in view["last_send"]["reason"]


# ----- SessionSpawner -----


def test_spawner_spawns(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager()
    sm.spawn_returns_id = "newly-spawned-id"
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_spawner_main", "spawn",
        payload={"session_type": "test", "display_name": "tester"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_spawner_main")
    assert view["last_spawn"]["spawned"] is True
    assert view["last_spawn"]["session_id"] == "newly-spawned-id"
    assert sm.spawned[0]["session_type"] == "test"
    assert sm.spawned[0]["display_name"] == "tester"


# ----- SessionArchiver -----


def test_archiver_archives(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager([FakeRecord(id="sid-1", display_name="x")])
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_archiver_main", "archive",
        payload={"session_id": "sid-1"},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_archiver_main")
    assert view["last_archive"]["archived"] is True
    assert "sid-1" in sm.archived


def test_archiver_rejects_empty(engine_with_cluster: Engine) -> None:
    sm = FakeSessionManager()
    engine_with_cluster.cache["__workflow__"] = {"session_manager": sm, "inbox": None}
    engine_actions.dispatch_action(
        engine_with_cluster, "session_archiver_main", "archive",
        payload={"session_id": ""},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_archiver_main")
    assert view["last_archive"]["archived"] is False


# ----- SessionTarget -----


def test_target_set_then_get(engine_with_cluster: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_cluster, "session_target_main", "set",
        payload={"session_id": "target-sid"},
    )
    engine_actions.dispatch_action(
        engine_with_cluster, "session_target_main", "get", payload={}
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_target_main")
    assert view["target"] == "target-sid"
    assert view["last_get"] == "target-sid"


def test_target_clear(engine_with_cluster: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_cluster, "session_target_main", "set",
        payload={"session_id": "x"},
    )
    engine_actions.dispatch_action(
        engine_with_cluster, "session_target_main", "set",
        payload={"session_id": None},
    )
    view = engine_actions.get_view_state(engine_with_cluster, "session_target_main")
    assert view["target"] is None
