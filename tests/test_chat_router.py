"""Tests for the ChatRouter node-type and its dispatch surface.

ChatRouter is the first concrete lift demonstrating the "same logic
node, different renderers" architectural commitment (2026-05-21
maintainer directive). The Tk and Streamlit surfaces both route
chat-submit bodies through this node instead of each reimplementing
the routing rules in their shell code.

The tests cover:
  - The node loads cleanly via Engine.discover().
  - send + routing-decision dict shape on success.
  - send fails gracefully when SessionManager is missing.
  - send fails gracefully when target is empty.
  - set_default_target mutates the node state across reruns.
  - dispatch_action returns OK/ERR consistent with the routing-decision.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from engine import actions as engine_actions
from engine.core import Engine


class FakeSessionManager:
    def __init__(self) -> None:
        self.sent: List[Tuple[str, str]] = []
        self.fail_with: Optional[Exception] = None

    def send(self, sid: str, body: str) -> None:
        if self.fail_with is not None:
            raise self.fail_with
        self.sent.append((sid, body))


class FakeInbox:
    def __init__(self) -> None:
        self.posts: List[Dict[str, Any]] = []
        self.fail_with: Optional[Exception] = None

    def post(self, **kwargs: Any) -> Path:
        if self.fail_with is not None:
            raise self.fail_with
        self.posts.append(kwargs)
        return Path("/fake/post")


@pytest.fixture
def engine_with_router(tmp_path: Path) -> Engine:
    """Boot an Engine + load a minimal scene containing one ChatRouter."""
    apeiron_root = Path(__file__).resolve().parents[1]
    engine = Engine(root_dir=apeiron_root)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "chat_router_main",
          "view": {"position": [0,0,5], "look_at": [0,0,0],
                   "width": 64, "height": 64, "fov_y_radians": 0.6},
          "nodes": [
            {"id": "chat_router_main", "type": "ChatRouter", "params": {}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    return engine


def test_node_loads(engine_with_router: Engine) -> None:
    node = engine_with_router.nodes.get("chat_router_main")
    assert node is not None
    assert not node.dead
    assert node.type_name == "ChatRouter"


def test_send_routes_to_session(engine_with_router: Engine) -> None:
    sm = FakeSessionManager()
    inbox = FakeInbox()
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
    ok, msg = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "hello session", "session_id": "sess-1"},
    )
    assert ok, msg
    assert sm.sent == [("sess-1", "hello session")]
    assert len(inbox.posts) == 1
    assert inbox.posts[0]["to"] == "sess-1"
    assert inbox.posts[0]["body"] == "hello session"
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is True
    assert view["last_route"]["target"] == "sess-1"


def test_send_with_empty_text_fails_gracefully(
    engine_with_router: Engine,
) -> None:
    engine_with_router.cache["__workflow__"] = {
        "session_manager": FakeSessionManager(),
        "inbox": FakeInbox(),
    }
    ok, msg = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "   ", "session_id": "sess-1"},
    )
    assert ok, msg  # dispatch succeeded; routing reported a soft-fail
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is False
    assert "empty body" in view["last_route"]["reason"]


def test_send_with_no_target_echoes_only(
    engine_with_router: Engine,
) -> None:
    """No target = echo-only mode. The inbox post happens with
    ``to=maintainer`` placeholder, but no session send. routed=True,
    delivered_to=[] — the chat panel still renders the typed body."""
    sm = FakeSessionManager()
    inbox = FakeInbox()
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
    ok, msg = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "echo me", "session_id": None},
    )
    assert ok, msg
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is True
    assert view["last_route"]["delivered_to"] == []
    assert "no active session" in view["last_route"]["reason"]
    # Echo happened, no session send.
    assert sm.sent == []
    assert len(inbox.posts) == 1
    assert inbox.posts[0]["to"] == "maintainer"
    assert inbox.posts[0]["body"] == "echo me"


def test_send_uses_default_target_when_no_explicit(
    engine_with_router: Engine,
) -> None:
    sm = FakeSessionManager()
    inbox = FakeInbox()
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
    engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="set_default_target",
        payload={"session_id": "default-sess"},
    )
    # Now send WITHOUT an explicit session_id — should fall back.
    ok, _ = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "to default", "session_id": None},
    )
    assert ok
    # Runtime mutations live in view-state, not node.state (per
    # architecture.md: node.state is the build-time output, view-state
    # is what runtime interactions produced).
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["default_target"] == "default-sess"
    # And send used it.
    assert sm.sent == [("default-sess", "to default")]


def test_send_propagates_session_send_failure(
    engine_with_router: Engine,
) -> None:
    sm = FakeSessionManager()
    sm.fail_with = RuntimeError("pipe broken")
    inbox = FakeInbox()
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
    ok, _ = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "will fail", "session_id": "sess-1"},
    )
    assert ok  # dispatch itself succeeded; routing soft-failed
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is False
    assert "pipe broken" in view["last_route"]["reason"]


def test_send_propagates_inbox_post_failure(
    engine_with_router: Engine,
) -> None:
    sm = FakeSessionManager()
    inbox = FakeInbox()
    inbox.fail_with = OSError("disk full")
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }
    engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "will fail", "session_id": "sess-1"},
    )
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is False
    assert "inbox.post failed" in view["last_route"]["reason"]
    # Critical: send was NOT called because inbox.post failed first.
    assert sm.sent == []


def test_send_works_without_inbox(engine_with_router: Engine) -> None:
    """If only SessionManager is registered (no inbox), send still works
    — the inbox echo is best-effort, not load-bearing for delivery."""
    sm = FakeSessionManager()
    engine_with_router.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": None,
    }
    ok, _ = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "no inbox", "session_id": "sess-1"},
    )
    assert ok
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is True
    assert sm.sent == [("sess-1", "no inbox")]


def test_send_fails_when_session_manager_missing(
    engine_with_router: Engine,
) -> None:
    """If the shell forgets to register __workflow__ AND a target is
    named, send soft-fails with a clear reason rather than crashing.
    (No-target echo-only case is covered by
    test_send_with_no_target_echoes_only.)"""
    # Don't register __workflow__ at all.
    ok, _ = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": "no SM", "session_id": "sess-1"},
    )
    assert ok  # dispatch ok; routing soft-failed
    view = engine_actions.get_view_state(engine_with_router, "chat_router_main")
    assert view["last_route"]["routed"] is False
    assert "session_manager" in view["last_route"]["reason"]


def test_unknown_action_returns_none(engine_with_router: Engine) -> None:
    """A handler that returns None means no state-delta; dispatch should
    still return OK (the action ran, just produced no change)."""
    ok, _ = engine_actions.dispatch_action(
        engine_with_router,
        renderer_id="chat_router_main",
        action_name="nonexistent_verb",
        payload={},
    )
    assert ok
